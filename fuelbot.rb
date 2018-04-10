require 'active_support/core_ext/hash/indifferent_access'
require 'date'
require 'esi-client-bvv'
require 'oauth2'
require 'set'
require 'slack-notifier'
require 'yaml'
require 'yaml/store'

#
# Load the configuration file named on the command line,
# or 'config.yaml' by default.
#
config = YAML.load_file(ARGV[0] || 'config.yaml').with_indifferent_access

#
# Get an OAuth2 access token for ESI.
#

client = OAuth2::Client.new(config[:client_id], config[:client_secret],
                            site: 'https://login.eveonline.com')

# Wrap the refresh token.
refresh_token = OAuth2::AccessToken.new(client, '',
                                        refresh_token: config[:refresh_token])

# Refresh to get the access token.
access_token = refresh_token.refresh!

#
# Get the owner information for the refresh token.
#
response = access_token.get('/oauth/verify')
character_info = response.parsed
character_id = character_info['CharacterID']

#
# Configure ESI with our access token.
#
ESI.configure do |conf|
  conf.access_token = access_token.token
end

universe_api = ESI::UniverseApi.new
corporation_api = ESI::CorporationApi.new
character_api = ESI::CharacterApi.new

#
# From the public information about the character, locate the corporation ID.
#
character = character_api.get_characters_character_id(character_id)
corporation_id = character.corporation_id

#
# Get the list of corporation structures.
#
structures = corporation_api.get_corporations_corporation_id_structures(corporation_id)

#
# If a list of system names has been configured, remove any structures
# which aren't in the listed systems.
#
if config[:systems]
  # Make a set of IDs for the named systems
  systems = universe_api.post_universe_ids(config[:systems]).systems
  system_ids = Set.new(systems.map(&:id))
  # Delete extractions in systems not included in that set
  structures.delete_if do |structure|
    !system_ids.include?(structure.system_id)
  end
end

# Sort by fuel expiry time.
structures.sort_by!(&:fuel_expires)

#
# Configure the number of days under which we should regard the
# fuelling state as either 'danger' or 'warning'.
#
DANGER_DAYS = config[:danger_days] || 7
WARNING_DAYS = config[:warning_days] || 14

#
# Translate the number of days left to a fuelling state.
#
def left_to_state(left)
  if left <= DANGER_DAYS
    'danger'
  elsif left <= WARNING_DAYS
    'warning'
  else
    'good'
  end
end

# Map from the raw structure to a set of useful properties
structures.map! do |s|
  # Public information for the structure.
  pub = universe_api.get_universe_structures_structure_id(s.structure_id)
  time_left = s.fuel_expires - DateTime.now
  {
    structure_id: s.structure_id,
    system: pub.name.sub(/ - .*$/, ''),
    name: pub.name.sub(/^.* - /, ''),
    time: s.fuel_expires,
    left: time_left,
    state: left_to_state(time_left),
    type_id: s.type_id
  }
end

# Initialise state store.
store = YAML::Store.new(config[:statefile])
store.transaction do
  store[:state] = {} unless store[:state]
end

# Remove any structures which are in the same state as last time
structures.delete_if do |structure|
  store.transaction do
    structure[:old_state] = store[:state][structure[:structure_id]] || 'unknown'
  end
  structure[:state] == structure[:old_state]
end

# Map each remaining structure to a Slack attachment
attachments = structures.map do |s|
  eve_time = s[:time].strftime('%A, %Y-%m-%d %H:%M:%S EVE time')
  {
    title: s[:name] + ' in ' + s[:system],
    color: s[:state],
    text: "Fuel expires in #{format('%.1f', s[:left])} days.\n" \
          "Services will go offline at #{eve_time}.\n" \
          "Old state: #{s[:old_state]}, new state: #{s[:state]}",
    fallback: "#{s[:name]} in #{s[:system]} fuel state is #{s[:state]}.",
    thumb_url: "https://imageserver.eveonline.com/Render/#{s[:type_id]}_128.png"
  }
end

# If we have something that is other than a 'good' state, take special action
panic = structures.find_index { |s| s[:state] != 'good' }
panic_text = panic ? '<!channel> :scream:' : ''

#
# Configure Slack.
#

slack_config = config[:slack]
notifier = Slack::Notifier.new slack_config[:webhook_url] do
  defaults slack_config[:defaults]
end

#
# Send a Slack ping if we have anything to say.
#
unless attachments.empty?
  notifier.ping panic_text + 'Structure fuel state changes:',
                attachments: attachments
end

#
# Write the state of these structures back for next time.
#
store.transaction do
  structures.each do |s|
    store[:state][s[:structure_id]] = s[:state]
  end
end

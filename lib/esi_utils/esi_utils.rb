module ESIUtils
  #
  # ESIUtils::Client
  #
  # API client that extends call_api to look for API warnings.
  #
  class ESIClient < ESI::ApiClient
    def initialize
      super
      @seen_warnings = Set.new
    end

    def log_warning_header(path, headers)
      return unless (warning = headers['Warning'])
      # Genericise the path, removing parameters
      g_path = path.gsub(%r{/\d+/}, '/id/')
      # Only notify about a given (genericised) path once
      return if @seen_warnings.include?(g_path)
      @seen_warnings.add(g_path)
      puts("Warning: '#{warning}' on path '#{g_path}")
    end

    def call_api(http_method, path, opts = {})
      data, code, headers = super(http_method, path, opts)
      log_warning_header(path, headers)
      [data, code, headers]
    end
  end
end

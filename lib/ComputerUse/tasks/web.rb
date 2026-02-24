require 'httparty'
require 'json'
require 'uri'

module ComputerUse
  extend Workflow
  self.name = 'ComputerUse'

  # Scout task: web search using Brave Search API
  # Get your free API key at: https://brave.com/search/api/
  # Set the environment variable: export BRAVE_API_KEY="your_key_here"
  input :query, :string, 'Search query string', nil, required: true
  task :brave => :json do |query|
    api_key = ENV['BRAVE_API_KEY']

    if api_key.nil? || api_key.empty?
      raise "BRAVE_API_KEY environment variable not set. Get your free API key at https://brave.com/search/api/"
    end

    response = HTTParty.get('https://api.search.brave.com/res/v1/web/search',
                            query: {
                              q: query,
                              count: 10
                            },
                            headers: {
                              'Accept' => 'application/json',
                              'Accept-Encoding' => 'gzip',
                              'X-Subscription-Token' => api_key
                            },
                            timeout: 10)

    unless response.success?
      raise ScoutException, "Brave Search API returned status #{response.code}: #{response.body}"
    end

    data = response.parsed_response
    results = []

    if data.is_a?(Hash) && data['web'] && data['web']['results'].is_a?(Array)
      data['web']['results'].each do |result|
        next unless result.is_a?(Hash)

        url = result['url']
        title = result['title'] || ''
        description = result['description'] || ''

        next if url.nil? || url.empty?

        text = if description.empty?
                 title
               else
                 "#{title} - #{description}"
               end

        text = text.gsub(/\s+/, ' ').strip
        results << { url: url, text: text } unless text.empty?
      end
    end

    results
  end

  # Scout task: web search using a SearXNG instance
  #
  # SearXNG is a self-hosted metasearch engine that can return JSON results.
  # Configure the instance base URL via:
  #   - input `searxng_url`
  #   - or env var `SEARXNG_URL`
  #
  # Optional (non-standard, instance-dependent) authentication:
  #   - env var `SEARXNG_API_KEY` or input `searxng_api_key` (sent as `X-API-Key`)
  #
  # Returns: [{url: "...", text: "..."}, ...]
  desc 'Web search using a SearXNG instance (self-hosted). Uses SEARXNG_URL or searxng_url.'
  input :query, :string, 'Search query string', nil, required: true
  input :count, :integer, 'Number of results to return (best-effort)', 10, required: false
  input :language, :string, 'Language code (e.g. en, en-US). Optional', nil, required: false
  input :categories, :string, 'Comma-separated categories (e.g. general, science). Optional', nil, required: false
  input :engines, :string, 'Comma-separated engines (instance dependent). Optional', nil, required: false
  input :safesearch, :integer, 'Safe-search level (0..2). Optional', 0, required: false
  input :time_range, :string, 'Time range (day, week, month, year). Optional', nil, required: false
  input :endpoint_path, :string, 'Endpoint path (usually /search)', '/search', required: false
  task :searxng => :json do |query, count, language, categories, engines, safesearch, time_range, endpoint_path|
    searxng_url = config :url, :searxng, env: 'SEARXNG_URL'
    searxng_url = searxng_url.to_s.strip

    if searxng_url.nil? || searxng_url.empty?
      raise ParameterException, 'SearXNG URL not set. Provide --searxng_url or set SEARXNG_URL'
    end

    begin
      uri = URI(searxng_url)
      raise URI::InvalidURIError if uri.scheme.nil? || uri.host.nil?
    rescue URI::InvalidURIError
      raise ParameterException, "Invalid SearXNG URL: #{searxng_url.inspect}"
    end

    base = searxng_url.sub(%r{/*\z}, '')
    # If the provided URL already points to /search, use it as-is; otherwise append endpoint_path
    if base =~ %r{/search\z} || base =~ %r{/search/\z}
      endpoint = base
      referer  = base.sub(%r{/search/?\z}, '')
    else
      path = endpoint_path.to_s.strip
      path = '/search' if path.empty?
      path = '/' + path unless path.start_with?('/')
      endpoint = base + path
      referer  = base
    end

    api_key = config :key, :searxng, env: 'SEARXNG_API_KEY'

    headers = {
      'Accept' => 'application/json',
      'User-Agent' => 'Scout-ComputerUse/1.0',
      # Some deployments expect these for JSON/AJAX access
      'Referer' => referer,
      'X-Requested-With' => 'XMLHttpRequest',
      'Accept-Language' => (language && !language.to_s.empty?) ? language : 'en-US,en;q=0.8'
    }
    headers['X-API-Key'] = api_key if api_key && !api_key.to_s.empty?

    target = [count.to_i, 1].max
    max_pages = [(target / 10.0).ceil + 1, 5].min

    results = []
    seen = {}

    1.upto(max_pages) do |pageno|
      query_params = {
        q: query,
        format: 'json',
        pageno: pageno
      }
      query_params[:language] = language if language && !language.to_s.empty?
      query_params[:categories] = categories if categories && !categories.to_s.empty?
      query_params[:engines] = engines if engines && !engines.to_s.empty?
      query_params[:safesearch] = safesearch.to_i if safesearch
      query_params[:time_range] = time_range if time_range && !time_range.to_s.empty?

      response = HTTParty.get(endpoint,
                              query: query_params,
                              headers: headers,
                              timeout: 15)

      unless response.success?
        raise ScoutException, "SearXNG returned status #{response.code}: #{response.body}"
      end

      data = response.parsed_response
      page_results = (Hash === data) ? data['results'] : nil
      page_results = [] unless Array === page_results

      break if page_results.empty?

      page_results.each do |r|
        next unless Hash === r

        url = r['url'].to_s.strip
        next if url.empty?
        next if seen[url]

        title = r['title'].to_s
        content = r['content'].to_s
        content = content.gsub(/<[^>]+>/, ' ')

        text = if content.strip.empty?
                 title
               elsif title.strip.empty?
                 content
               else
                 "#{title} - #{content}"
               end

        text = text.gsub(/\s+/, ' ').strip
        next if text.empty?

        results << { url: url, text: text }
        seen[url] = true
      end

      break if results.length >= target
    end

    results.first(target)
  end

  export_exec :searxng
end

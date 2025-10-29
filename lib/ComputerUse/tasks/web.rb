require 'httparty'
require 'json'

module ComputerUse
  extend Workflow
  self.name = 'ComputerUse'

  # Scout task: web search using Brave Search API
  # Get your free API key at: https://brave.com/search/api/
  # Set the environment variable: export BRAVE_API_KEY="your_key_here"
  input :query, :string, 'Search query string', nil, required: true

  task :duckduckgo => :json do |query|
    # Check for API key
    api_key = ENV['BRAVE_API_KEY']

    if api_key.nil? || api_key.empty?
      raise "BRAVE_API_KEY environment variable not set. Get your free API key at https://brave.com/search/api/"
    end

    # Use Brave Search API for real web search results
    response = HTTParty.get('https://api.search.brave.com/res/v1/web/search',
      query: {
        q: query,
        count: 10  # Number of results to return
      },
      headers: {
        'Accept' => 'application/json',
        'Accept-Encoding' => 'gzip',
        'X-Subscription-Token' => api_key
      },
      timeout: 10
    )

    unless response.success?
      raise "Brave Search API returned status #{response.code}: #{response.body}"
    end

    data = response.parsed_response
    results = []

    # Extract web search results
    if data.is_a?(Hash) && data['web'] && data['web']['results'].is_a?(Array)
      data['web']['results'].each do |result|
        next unless result.is_a?(Hash)

        url = result['url']
        title = result['title'] || ''
        description = result['description'] || ''

        # Skip if no URL
        next if url.nil? || url.empty?

        # Combine title and description for context
        text = if description.empty?
                 title
               else
                 "#{title} - #{description}"
               end

        # Clean up text (remove excessive whitespace)
        text = text.gsub(/\s+/, ' ').strip

        results << { url: url, text: text } unless text.empty?
      end
    end

    # If no results found, return empty array
    results
  end

  export_exec :duckduckgo
end

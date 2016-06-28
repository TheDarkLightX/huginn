require 'rss'

module Agents
  class RssAgent < Agent
    include WebRequestConcern

    cannot_receive_events!
    can_dry_run!
    default_schedule "every_1d"

    gem_dependency_check { defined?(Feedjira::Feed) }

    DEFAULT_EVENTS_ORDER = [['{{date_published}}', 'time'], ['{{last_updated}}', 'time']]

    description do
      <<-MD
        The RSS Agent consumes RSS feeds and emits events when they change.

        For complex feeds with additional field types, we recommend using a WebsiteAgent.  See [this example](https://github.com/cantino/huginn/wiki/Agent-configuration-examples#itunes-trailers).

        If you want to *output* an RSS feed, use the DataOutputAgent.

        Options:

          * `url` - The URL of the RSS feed (an array of URLs can also be used; items with identical guids across feeds will be considered duplicates).
          * `expected_update_period_in_days` - How often you expect this RSS feed to change.  If more than this amount of time passes without an update, the Agent will mark itself as not working.
          * `headers` - When present, it should be a hash of headers to send with the request.
          * `basic_auth` - Specify HTTP basic auth parameters: `"username:password"`, or `["username", "password"]`.
          * `disable_ssl_verification` - Set to `true` to disable ssl verification.
          * `disable_url_encoding` - Set to `true` to disable url encoding.
          * `force_encoding` - Set `force_encoding` to an encoding name if the website is known to respond with a missing, invalid or wrong charset in the Content-Type header.  Note that a text content without a charset is taken as encoded in UTF-8 (not ISO-8859-1).
          * `user_agent` - A custom User-Agent name (default: "Faraday v#{Faraday::VERSION}").
          * `max_events_per_run` - Limit number of events created (items parsed) per run for feed.

        # Ordering Events

        #{description_events_order}

        In this Agent, the default value for `events_order` is `#{DEFAULT_EVENTS_ORDER.to_json}`.
      MD
    end

    def default_options
      {
        'expected_update_period_in_days' => "5",
        'url' => "https://github.com/cantino/huginn/commits/master.atom"
      }
    end

    event_description <<-MD
      Events look like:

          {
            "feed": {
              "id": "...",
              "type": "atom",
              "generator": "...",
              "url": "http://example.com/",
              "links": [
                { "href": "http://example.com/", "rel": "alternate", "type": "text/html" },
                { "href": "http://example.com/index.atom", "rel": "self", "type": "application/atom+xml" }
              ],
              "title": "Some site title",
              "description": "Some site description",
              "copyright": "...",
              "icon": "http://example.com/icon.png",
              "author": "...",
              "authors": [ "..." ],
              "date_published": "Thu, 11 Sep 2014 01:30:00 -0700",
              "last_updated": "Thu, 11 Sep 2014 01:30:00 -0700"
            },
            "id": "829f845279611d7925146725317b868d",
            "url": "http://example.com/...",
            "title": "Some title",
            "description": "Some description",
            "content": "Some content",
            "author": "...",
            "authors": [ "..." ],
            "categories": [ "..." ],
            "date_published": "2014-09-11 01:30:00 -0700",
            "last_updated": "Thu, 11 Sep 2014 01:30:00 -0700"
          }

    MD

    def working?
      event_created_within?((interpolated['expected_update_period_in_days'].presence || 10).to_i) && !recent_error_logs?
    end

    def validate_options
      errors.add(:base, "url is required") unless options['url'].present?

      unless options['expected_update_period_in_days'].present? && options['expected_update_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_update_period_in_days' to indicate how many days can pass without an update before this Agent is considered to not be working")
      end

      validate_web_request_options!
      validate_events_order
    end

    def events_order
      super.presence || DEFAULT_EVENTS_ORDER
    end

    def check
      check_urls(Array(interpolated['url']))
    end

    protected

    def check_urls(urls)
      new_events = []
      max_events = (interpolated['max_events_per_run'].presence || 0).to_i

      urls.each do |url|
        begin
          response = faraday.get(url)
          if response.success?
            feed = Feedjira::Feed.parse(response.body)
            new_events.concat feed_to_events(feed)
          else
            error "Failed to fetch #{url}: #{response.inspect}"
          end
        rescue => e
          error "Failed to fetch #{url} with message '#{e.message}': #{e.backtrace}"
        end
      end

      created_event_count = 0
      sort_events(new_events).each.with_index do |event, index|
        entry_id = event.payload[:id]
        if check_and_track(entry_id)
          unless max_events && max_events > 0 && index >= max_events
            created_event_count += 1
            create_event(event)
          end
        end
      end
      log "Fetched #{urls.to_sentence} and created #{created_event_count} event(s)."
    end

    def check_and_track(entry_id)
      memory['seen_ids'] ||= []
      if memory['seen_ids'].include?(entry_id)
        false
      else
        memory['seen_ids'].unshift entry_id
        memory['seen_ids'].pop if memory['seen_ids'].length > 500
        true
      end
    end

    LINK_ATTRS = %i[href rel type hreflang title length]

    unless dependencies_missing?
      class AtomAuthor
        include SAXMachine

        element :name
        element :email
        element :uri
      end

      class AtomLink
        include SAXMachine

        LINK_ATTRS.each do |attr|
          attribute attr
        end

        def to_json(options = nil)
          LINK_ATTRS.each_with_object({}) { |key, hash|
            if value = __send__(key)
              hash[key] = value
            end
          }.to_json(options)
        end
      end

      class RssLinkElement
        include SAXMachine

        value :href

        def to_json(options = nil)
          {
            href: href
          }.to_json(options)
        end
      end

      module HasLinks
        def self.included(mod)
          mod.module_exec do
            sax_config.top_level_elements['link'].clear
            sax_config.collection_elements['link'].clear

            case name
            when /RSS/
              elements :link, class: RssLinkElement, as: :rss_links

              case name
              when /FeedBurner/
                elements :'atok10:link', class: AtomLink, as: :atom_links

                def links
                  @links ||= [*rss_links, *atom_links]
                end
              else
                alias_method :links, :rss_links
              end
            else
              elements :link, class: AtomLink, as: :links
            end

            def alternate_link
              links.find { |link|
                link.is_a?(AtomLink) &&
                  link.rel == 'alternate' &&
                  (link.type == 'text/html'|| link.type.nil?)
              }
            end

            def url
              @url ||= (alternate_link || links.first).try!(:href)
            end
          end
        end
      end

      module FeedEntryExtensions
        def self.included(mod)
          mod.module_exec do
            include HasLinks
          end
        end
      end

      module FeedExtensions
        def self.included(mod)
          mod.module_exec do
            include HasLinks

            element  :id, as: :feed_id
            element  :generator
            elements :rights
            element  :published
            element  :updated
            element  :icon
            elements :author, class: AtomAuthor, as: :authors

            if /RSS/ === name
              element :guid, as: :feed_id
              element :managingEditor
              element :pubDate, as: :published
              element :'dc:date', as: :published
              element :lastBuildDate, as: :updated
              element :image, value: :url, as: :icon
            end

            sax_config.collection_elements.each_value do |collection_elements|
              collection_elements.each do |collection_element|
                collection_element.accessor == 'entries' &&
                  (entry_class = collection_element.data_class).is_a?(Class) or next

                entry_class.send :include, FeedEntryExtensions
              end
            end
          end
        end
      end

      Feedjira::Feed.feed_classes.each do |feed_class|
        feed_class.send :include, FeedExtensions
      end
    end

    def feed_data(feed)
      type =
        case feed.class.name
        when /Atom/
          'atom'
        else
          'rss'
        end

      authors = feed.authors.map(&:name).presence ||
                Array(feed.try(:managingEditor) || feed.try(:itunes_author))

      {
        id: feed.feed_id,
        type: type,
        url: feed.url,
        links: feed.links,
        title: feed.title,
        description: feed.description,
        copyright: feed.try(:copyright) || feed.rights.join("\n").presence,
        generator: feed.generator,
        icon: feed.icon,
        authors: authors,
        date_published: feed.published,
        last_updated: feed.updated || feed.published,
      }
    end

    def entry_data(entry)
      description = entry.summary
      content = entry.content || description
      id = entry.try(:entry_id) || Digest::MD5.hexdigest(content || '')
      author = entry.author || entry.try(:itunes_author)

      {
        id: id,
        url: entry.url,
        links: entry.links,
        title: entry.title,
        description: description,
        content: content,
        image: entry.try(:image),
        author: author,
        authors: Array(author),
        categories: Array(entry.try(:categories)),
        date_published: entry.published,
        last_updated: entry.try(:updated) || entry.published,
      }
    end

    def feed_to_events(feed)
      payload_base = {
        feed: feed_data(feed)
      }

      feed.entries.map { |entry|
        Event.new(payload: payload_base.merge(entry_data(entry)))
      }
    end
  end
end

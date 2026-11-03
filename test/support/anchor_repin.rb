# frozen_string_literal: true

require 'yaml'

module Conformance
  # Moves the line numbers the conformance gates pin after the lines themselves
  # moved. A pin is only ever moved to a range where its quoted text still is, so
  # this can't paper over drift: a fragment or promise that is gone is reported as
  # unresolved, for a person to decide about. Everything here works from the text
  # in the files, in three passes, because each reads the result of the one before:
  #
  #   1. anchor records in test/conformance/ledger_anchors/*.yml, by their fragment
  #   2. the ledger's references to those records, `path#L1-L2` and `path:1-2,3`
  #   3. cases.yml sources, by their promise; the ledger's own lines moved in step 2
  class AnchorRepin
    LEDGER = 'docs/idea/parity-divergences.md'
    RECORDS = 'test/conformance/ledger_anchors/*.yml'
    CASES = 'test/conformance/cases.yml'
    LINE_ANCHOR = /\A(?<path>.+)#L(?<from>\d+)(?:-L(?<to>\d+))?\z/
    TOP_DIRS = '(?:lib|app|config|frontend|docs|test|exe|bin)'
    LINK_REF = %r{#{TOP_DIRS}[\w./-]*?\.\w+#L\d+(?:-L\d+)?}
    COLON_REF = %r{(#{TOP_DIRS}[\w./-]*?\.\w+):(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)}

    Report = Struct.new(:records, :references, :sources, :unresolved) do
      def changes = records.size + references + sources.size
      def clean? = changes.zero? && unresolved.empty?
    end

    attr_reader :report

    def initialize(root)
      @root = root
      @files = {}
      @report = Report.new([], 0, [], [])
    end

    def run
      moved = repin_records
      sync_ledger(moved)
      sync_cases
      report
    end

    def write
      @files.each { |path, text| File.write(path, text) }
    end

    private

    def read(relative)
      path = File.join(@root, relative)
      @files[path] || File.read(path)
    end

    def store(relative, text)
      path = File.join(@root, relative)
      @files[path] = text unless text == File.read(path)
    end

    def repin_records
      moved = Hash.new { |hash, entry| hash[entry] = {} }
      Dir[File.join(@root, RECORDS)].each do |file|
        relative = file.delete_prefix("#{@root}/")
        text = read(relative)
        YAML.load_file(file).each do |record|
          target = repinned_anchor(record)
          next if target == record['anchor']

          moved[record['entry']][record['anchor']] = target
          report.records << [record['anchor'], target]
          text = text.gsub(/(anchor: ["']?)#{Regexp.escape(record['anchor'])}(["']?)$/) do
            "#{::Regexp.last_match(1)}#{target}#{::Regexp.last_match(2)}"
          end
        end
        store(relative, text)
      end
      moved
    end

    def repinned_anchor(record)
      match = LINE_ANCHOR.match(record['anchor']) or return record['anchor']
      path = File.join(@root, match[:path])
      return record['anchor'] unless File.file?(path)

      from = match[:from].to_i
      width = (match[:to] || match[:from]).to_i - from
      fragment = normalize(record['fragment'])
      lines = File.readlines(path)
      found = nearest(from, lines.size) do |line|
        line + width <= lines.size && normalize(lines[(line - 1)..(line - 1 + width)].join).include?(fragment)
      end
      unless found
        report.unresolved << "#{record['anchor']}: fragment not found, in \"#{record['entry']}\""
        return record['anchor']
      end
      format_anchor(match[:path], found, found + width, ranged: !match[:to].nil?)
    end

    def format_anchor(path, first, last, ranged:) = ranged ? "#{path}#L#{first}-L#{last}" : "#{path}#L#{first}"

    # Lines count outward from `from`, so of two copies the closer one wins.
    def nearest(from, size)
      (0..size).each do |distance|
        [from + distance, from - distance].uniq.each do |line|
          return line if line.between?(1, size) && yield(line)
        end
      end
      nil
    end

    def normalize(text) = text.to_s.lines.map(&:strip).reject(&:empty?).join(' ').squeeze(' ')

    def sync_ledger(moved)
      by_entry = records.group_by { |record| record['entry'] }
      sections = read(LEDGER).split(/^(?=## )/).map do |section|
        heading = section[/\A## (.+)$/, 1]
        by_entry[heading] ? sync_section(section, by_entry[heading].map { |r| r['anchor'] }, moved[heading]) : section
      end
      store(LEDGER, sections.join)
    end

    # Read back through the pending text so pass 1's rewrites count.
    def records
      Dir[File.join(@root, RECORDS)].flat_map { |file| YAML.safe_load(read(file.delete_prefix("#{@root}/"))) }
    end

    def sync_section(section, anchors, moved)
      section.gsub(LINK_REF) { |ref| count_change(ref, resolve_ref(ref, anchors, moved)) }
             .gsub(COLON_REF) { |whole| sync_colon_ref(whole, anchors, moved) }
    end

    # One reference, `path:1-2,3`, may name several records, so what its earlier
    # items took is not on offer to the later ones.
    def sync_colon_ref(whole, anchors, moved)
      path, list = COLON_REF.match(whole).captures
      available = anchors.dup
      items = list.split(',').map do |item|
        first, last = item.split('-')
        ref = format_anchor(path, first, last || first, ranged: !last.nil?)
        resolved = resolve_ref(ref, available, moved)
        available.delete(resolved)
        match = LINE_ANCHOR.match(resolved)
        match[:to] ? "#{match[:from]}-#{match[:to]}" : match[:from]
      end
      count_change(whole, "#{path}:#{items.join(',')}")
    end

    def resolve_ref(ref, anchors, moved)
      return moved[ref] if moved.key?(ref)
      return ref if anchors.include?(ref)

      closest_anchor(ref, anchors) || ref
    end

    # A reference no record names and no move explains is either already stale or
    # prose naming unpinned lines, which has to stay. A shift keeps a range's width,
    # so only a record of the same width can be what a stale one meant.
    def closest_anchor(ref, anchors)
      match = LINE_ANCHOR.match(ref)
      anchors.select { |anchor| same_file_and_width?(anchor, match) }
             .min_by { |anchor| (LINE_ANCHOR.match(anchor)[:from].to_i - match[:from].to_i).abs }
    end

    def same_file_and_width?(anchor, match)
      candidate = LINE_ANCHOR.match(anchor)
      candidate[:path] == match[:path] && span(candidate) == span(match)
    end

    def span(match) = (match[:to] || match[:from]).to_i - match[:from].to_i

    def count_change(before, after)
      report.references += 1 unless before == after
      after
    end

    def sync_cases
      id = nil
      entries = YAML.safe_load(read(CASES))
      promises = entries.to_h { |entry| [entry['id'], entry['promise']] }
      lines = read(CASES).lines.map do |line|
        id = ::Regexp.last_match(1) if line =~ /^- id: (\S+)/
        source = line[/^  source: (\S+)$/, 1]
        next line unless source && promises[id]

        target = relocate_source(id, source, promises[id])
        report.sources << [id, source, target] unless target == source
        line.sub(source, target)
      end
      store(CASES, lines.join)
    end

    def relocate_source(case_id, source, promise)
      match = LINE_ANCHOR.match(source) or return source
      lines = read(match[:path]).lines
      from = match[:from].to_i
      width = (match[:to] || match[:from]).to_i - from
      wanted = normalize(promise)
      found = nearest(from, lines.size) { |line| source_at?(lines, line, width, wanted, match[:path]) }
      unless found
        report.unresolved << "#{source}: promise of #{case_id} not found at that width"
        return source
      end
      format_anchor(match[:path], found, found + width, ranged: !match[:to].nil?)
    end

    # What Inventory#validate_promise! requires of a range.
    def source_at?(lines, line, width, wanted, path)
      return false if line + width > lines.size

      range = lines[(line - 1)..(line - 1 + width)]
      return false unless normalize(range.join).include?(wanted)
      return false if width.positive? && !reader_can_start_at?(lines, line)

      path != LEDGER || spans_own_heading?(range, wanted)
    end

    def reader_can_start_at?(lines, line)
      opening = lines[line - 1]
      line == 1 || opening.start_with?('#') || (!opening.strip.empty? && lines[line - 2].strip.empty?)
    end

    def spans_own_heading?(range, wanted)
      range.each_with_index.any? do |text, index|
        text.start_with?('## ') && normalize(range[index..].join).include?(wanted)
      end
    end
  end
end

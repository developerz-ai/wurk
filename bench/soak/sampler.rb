# frozen_string_literal: true

module WurkSoak
  # Process-memory and Redis-size readings shared by bench/rss_soak.rb (plan
  # 101/08 M0) and bench/soak/run.rb (101/12 T1). Linux only: everything comes
  # from /proc, and a process that is gone (or unreadable) reads as nil rather
  # than raising, because chaos kills children between listing and reading.
  module Sampler
    # smaps_rollup field => key, all in kB. Shared = what fork's copy-on-write
    # still shares with the parent and siblings; Pss charges it 1/N to each.
    FIELDS = {
      'Rss' => :rss, 'Pss' => :pss,
      'Shared_Clean' => :shared_clean, 'Shared_Dirty' => :shared_dirty,
      'Private_Clean' => :private_clean, 'Private_Dirty' => :private_dirty
    }.freeze

    module_function

    def parse_smaps_rollup(text)
      row = {}
      text.each_line do |line|
        name, value = line.split(':', 2)
        key = FIELDS[name]
        row[key] = value.to_i if key
      end
      return nil unless row[:rss]

      shared = row.fetch(:shared_clean, 0) + row.fetch(:shared_dirty, 0)
      row.merge(shared: shared, shared_ratio: row[:rss].zero? ? 0.0 : (shared.to_f / row[:rss]).round(3))
    end

    def memory(pid)
      parse_smaps_rollup(File.read("/proc/#{pid}/smaps_rollup"))
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
      nil
    end

    # [pid, ppid, start ticks] from /proc/<pid>/stat. comm may hold spaces and
    # parentheses, so fields are counted from the last ')'.
    def parse_stat(text)
      head, rest = text.split(/\)(?=[^)]*\z)/, 2)
      fields = rest.split
      [Integer(head[/\A\d+/]), Integer(fields[1]), Integer(fields[19])]
    end

    def children(ppid)
      Dir.glob('/proc/[0-9]*/stat').filter_map do |path|
        pid, parent, = parse_stat(File.read(path))
        pid if parent == ppid
      rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
        nil
      end.sort
    end

    TICKS = Integer(ENV.fetch('SOAK_CLK_TCK', '100'))

    # Seconds since the process started, or nil once it is gone.
    def age(pid)
      _, _, start = parse_stat(File.read("/proc/#{pid}/stat"))
      File.read('/proc/uptime').split.first.to_f - (start.to_f / TICKS)
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end

    # Least-squares slope of [[x, y], ...]; nil when it is undefined.
    def slope(points)
      return nil if points.size < 2

      n = points.size.to_f
      mx = points.sum { |x, _| x } / n
      my = points.sum { |_, y| y } / n
      var = points.sum { |x, _| (x - mx)**2 }
      return nil if var.zero?

      points.sum { |x, y| (x - mx) * (y - my) } / var
    end

    def key_family(key) = key[/\A[^:|-]+/] || key

    # used_memory, DBSIZE and a key count per family (the part before the
    # first `:`, `|` or `-`). SCAN, not KEYS: the soak's Redis is private, but
    # a long run holds enough keys that one KEYS would stall the workers.
    def redis(conn)
      info = conn.call('INFO', 'memory')
      families = Hash.new(0)
      cursor = '0'
      loop do
        cursor, keys = conn.call('SCAN', cursor, 'COUNT', 1000)
        keys.each { |k| families[key_family(k)] += 1 }
        break if cursor == '0'
      end
      { used_memory: info[/^used_memory:(\d+)/, 1].to_i, dbsize: conn.call('DBSIZE'),
        families: families.sort.to_h }
    end
  end
end

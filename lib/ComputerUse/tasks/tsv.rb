require 'json'
require 'tempfile'
require 'scout'

module ComputerUse
  module TSVTasks
    TYPES = %w(single list flat double).freeze
    MERGES = %w(true false concat).freeze
    module_function

    def optional(value)
      value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?)
    end

    def file!(path)
      raise ParameterException, "TSV file not found: #{path}" unless File.file?(path.to_s)
    end

    def type!(type)
      raise ParameterException, 'type must be single, list, flat, or double' unless optional(type) || TYPES.include?(type.to_s)
    end

    def merge_absent?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def merge_option(value)
      return nil if merge_absent?(value)
      raise ParameterException, 'merge must be true, false, or concat' unless MERGES.include?(value.to_s)
      {'true' => true, 'false' => false, 'concat' => :concat}.fetch(value.to_s)
    end

    def open_options(type:, key_field:, fields:, sep:, sep2:, header_hash:, merge: nil,
                     one2one: false, identifiers: nil, namespace: nil, field: nil, cast: nil)
      options = {sep: sep, sep2: sep2, header_hash: header_hash, one2one: one2one, persist: false}
      options[:type] = type.to_sym unless optional(type)
      options[:key_field] = key_field unless optional(key_field)
      options[:fields] = fields unless optional(fields)
      options[:merge] = merge_option(merge) unless merge_absent?(merge)
      options[:identifiers] = identifiers unless optional(identifiers)
      options[:namespace] = namespace unless optional(namespace)
      options[:cast] = cast.to_sym unless optional(cast)
      options[:field] = field unless optional(field)
      options
    end

    def cast!(cast)
      return nil if optional(cast)
      raise ParameterException, 'cast must be to_i or to_f' unless %w[to_i to_f].include?(cast.to_s)
      cast.to_sym
    end

    def rename_metadata!(table, key_name: nil, field_names: nil, namespace: nil, identifiers: nil,
                         cast: nil, type: nil)
      unless optional(key_name)
        raise ParameterException, 'key field name cannot be empty' if key_name.to_s.empty?
        table.key_field = key_name.to_s
      end
      unless optional(field_names)
        names = Array(field_names).map(&:to_s)
        raise ParameterException, "expected #{Array(table.fields).length} field names" unless names.length == Array(table.fields).length
        raise ParameterException, 'field names must be nonempty and unique' if names.any?(&:empty?) || names.uniq.length != names.length
        table.fields = names
      end
      table.namespace = namespace unless optional(namespace)
      table.identifiers = identifiers unless optional(identifiers)
      table.cast = cast!(cast) unless optional(cast)
      unless optional(type)
        target_type = type.to_sym
        raise ParameterException, 'type must be single, list, flat, or double' unless TYPES.include?(target_type.to_s)
        table = table.public_send("to_#{target_type}") unless table.type.to_sym == target_type
      end
      table
    end

    def copy(value)
      value.is_a?(Array) ? value.map { |item| copy(item) } : value
    end

    def clone_table(table)
      metadata = table.annotation_hash.reject { |name, _| name.to_sym == :filename }
      result = TSV.setup({}, metadata)
      table.each { |key, value| result[key] = copy(value) }
      result
    end

    def right_replacement(left, right)
      result = clone_table(left)
      right.each { |key, value| result[key] = copy(value) }
      result
    end

    def render(table, sep: "\t", sep2: '|', header_hash: '#')
      clean = clone_table(table)
      clean.to_s(preamble: true, sep: sep, sep2: sep2, header_hash: header_hash).to_s
    end

    def canonical_render(table)
      render(table, sep: "\t", sep2: '|', header_hash: '#')
    end

    def replace_source!(path, text)
      source = File.expand_path(path.to_s)
      raise ParameterException, "TSV source must be a regular non-symlink file: #{path}" unless File.file?(source) && !File.symlink?(source)
      directory = File.dirname(source)
      source_mode = File.stat(source).mode & 0o7777
      directory_mode = File.stat(directory).mode & 0o7777
      writable = (source_mode & 0o222) != 0 && (directory_mode & 0o222) != 0 && File.writable?(source) && File.writable?(directory)
      raise ParameterException, "TSV source is not writable: #{path}" unless writable
      tempfile = Tempfile.new(['.computeruse-tsv-', '.tmp'], directory)
      begin
        tempfile.binmode
        tempfile.write(text)
        tempfile.flush
        tempfile.fsync
        tempfile.close
        File.chmod(source_mode, tempfile.path)
        File.rename(tempfile.path, source)
      ensure
        tempfile.close! if tempfile
      end
      source
    rescue SystemCallError => e
      raise ParameterException, "Could not atomically update TSV source #{path}: #{e.message}"
    end

    def scalar?(value)
      value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end

    def stringify(values)
      values.map do |value|
        raise ParameterException, 'row values must be JSON scalars' unless scalar?(value)
        value.nil? ? nil : value.to_s
      end
    end

    def json_row(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError => e
      raise ParameterException, "row must be valid JSON: #{e.message}"
    end

    def validate_row(type, row, fields)
      case type.to_sym
      when :single
        raise ParameterException, 'single TSV row must be one scalar' unless scalar?(row)
        row.nil? ? nil : row.to_s
      when :list
        raise ParameterException, "list row must contain #{fields} scalar fields" unless row.is_a?(Array) && row.length == fields && row.all? { |v| scalar?(v) }
        stringify(row)
      when :flat
        raise ParameterException, 'flat row must be an array of scalar values' unless row.is_a?(Array) && row.all? { |v| scalar?(v) }
        stringify(row)
      when :double
        valid = row.is_a?(Array) && row.length == fields && row.all? { |cell| cell.is_a?(Array) && cell.all? { |v| scalar?(v) } }
        raise ParameterException, "double row must contain #{fields} arrays of scalars" unless valid
        row.map { |cell| stringify(cell) }
      else
        raise ParameterException, "unsupported TSV type: #{type}"
      end
    end
  end

  desc 'Summarize a TSV row count, materialized key count, type and fields.'
  input :file, :path, 'TSV file path', nil, required: true
  input :key_field, :string, 'Override key field', nil
  input :fields, :array, 'Select value fields', nil
  input :type, :string, 'TSV type override', nil
  input :sep, :string, 'Column separator', "\t"
  input :sep2, :string, 'Multi-value separator', '|'
  input :header_hash, :string, 'Header marker', '#'
  input :merge, :string, 'Duplicate-key merge: true, false, concat', nil
  input :one2one, :boolean, 'Use Scout one2one behavior', false
  input :cast, :string, 'Persist parser cast metadata: to_i or to_f', nil
  input :identifiers, :path, 'Identifier mapping path metadata', nil
  input :namespace, :string, 'TSV namespace metadata', nil
  input :new_key_field, :string, 'Rename the key field in the materialized table', nil
  input :rename_fields, :array, 'Rename value fields in order', nil
  input :new_type, :string, 'Persist a converted TSV type: single, list, flat, or double', nil
  task tsv_info: :json do |file, key_field, fields, type, sep, sep2, header_hash, merge, one2one, cast, identifiers, namespace, new_key_field, rename_fields, new_type|
    TSVTasks.file!(file); TSVTasks.type!(type); TSVTasks.type!(new_type); TSVTasks.cast!(cast)
    open_options = TSVTasks.open_options(type: type, key_field: key_field, fields: fields, sep: sep, sep2: sep2, header_hash: header_hash, merge: merge, one2one: one2one)
    table = if sep == ','
      csv = TSV.csv(file, headers: true, type: (type || :double).to_sym, col_sep: sep)
      if !TSVTasks.optional(key_field) || !TSVTasks.optional(fields)
        selected_fields = TSVTasks.optional(fields) ? csv.fields : Array(fields).map(&:to_s)
        selected_key = TSVTasks.optional(key_field) ? csv.key_field : key_field.to_s
        csv = csv.reorder(selected_key, selected_fields, one2one: one2one, merge: TSVTasks.merge_option(merge), type: (type || :double).to_sym)
      end
      csv
    else
      parser = TSV::Parser.new(file, sep: sep, header_hash: header_hash, type: (type || :double).to_sym)
      parser.traverse(data: false) { |_key, _value, _fields| }
      TSV.open(file, open_options)
    end
    rows = table.keys.length
    changed = [new_key_field, rename_fields, cast, identifiers, namespace, new_type].any? { |v| !TSVTasks.optional(v) }
    table = TSVTasks.rename_metadata!(table, key_name: new_key_field, field_names: rename_fields,
      namespace: namespace, identifiers: identifiers, cast: cast, type: new_type)
    value_fields = table.fields || []
    TSVTasks.replace_source!(file, TSVTasks.render(table, sep: sep, sep2: sep2, header_hash: header_hash)) if changed
    {key_field: table.key_field, fields: value_fields, type: table.type, cast: table.cast,
     namespace: table.namespace, identifiers: table.identifiers, source_rows: rows,
     unique_keys: table.keys.length,
     entity_field_candidates: value_fields.select { |name| Entity.formats.include?(name) },
     registered_entity_formats: Entity.formats.keys}
  end
  export :tsv_info

  desc 'Read a TSV and return normalized Scout TSV text.'
  input :file, :path, 'TSV file', nil, required: true
  input :keys, :array, 'Exact keys to retain, empty means all', []
  input :key_field, :string, 'Override key field', nil
  input :fields, :array, 'Select value fields', nil
  input :type, :string, 'TSV type', :double
  input :sep, :string, 'Column separator', "\t"
  input :sep2, :string, 'Multi-value separator', '|'
  input :header_hash, :string, 'Header marker; empty disables it', '#'
  input :cast, :string, 'Scout cast option', nil
  input :select, :string, 'Scout selection option', nil
  input :grep, :string, 'Scout grep option', nil
  input :merge, :string, 'Duplicate-key merge: true, false, concat', true
  input :one2one, :boolean, 'Use Scout one2one behavior', false
  input :field, :string, 'Scout convenience field option', nil
  input :identifiers, :path, 'Identifier mapping path metadata', nil
  input :namespace, :string, 'TSV namespace metadata', nil
  input :new_key_field, :string, 'Rename the key field in output', nil
  input :rename_fields, :array, 'Rename value fields in order', nil
  input :persist, :boolean, 'Use parser/cache persistence', false
  extension :tsv
  task tsv_read: :string do |file, keys, key_field, fields, type, sep, sep2, header_hash, cast, select, grep, merge, one2one, field, identifiers, namespace, new_key_field, rename_fields, persist|
    TSVTasks.file!(file); TSVTasks.type!(type)
    opts = TSVTasks.open_options(type: type, key_field: key_field, fields: fields, sep: sep,
      sep2: sep2, header_hash: header_hash, merge: merge, one2one: one2one, field: field,
      identifiers: identifiers, namespace: namespace, cast: cast)
    if persist && sep != ','
      opts[:persist] = true
      opts[:persist_engine] = 'HDB'
      opts[:persist_path] = File.join(self.files_dir, 'source.hdb')
    end
    table = if sep == ','
      parsed = TSV.csv(file, headers: true, type: (type || :double).to_sym, col_sep: sep)
      source_key = parsed.key_field.to_s
      source_fields = [source_key, *Array(parsed.fields).map(&:to_s)]
      selected_fields = TSVTasks.optional(fields) ? source_fields.drop(1) : Array(fields).map(&:to_s)
      requested_key = TSVTasks.optional(key_field) ? source_key : key_field.to_s
      raise ParameterException, 'merge=false is unsupported for CSV input by TSV.csv' if merge.to_s == 'false'
      selected = if requested_key == source_key && selected_fields == source_fields.drop(1)
        parsed
      else
        raise ParameterException, 'one2one CSV field/key reordering is unsupported' if one2one
        parsed.reorder(requested_key, selected_fields, merge: TSVTasks.merge_option(merge), type: (type || :double).to_sym)
      end
      selected.namespace = namespace unless TSVTasks.optional(namespace)
      selected.identifiers = identifiers unless TSVTasks.optional(identifiers)
      unless TSVTasks.optional(cast)
        raise ParameterException, 'CSV cast supports only to_i and to_f' unless %w[to_i to_f].include?(cast.to_s)
        casted = TSV.setup({}, selected.annotation_hash)
        selected.each { |row_key, value| casted[row_key] = TSV.cast_value(value, cast.to_sym) }
        selected = casted
      end
      selected = selected.select(select) unless TSVTasks.optional(select)
      unless TSVTasks.optional(grep)
        pattern = Regexp.new(grep.to_s)
        matched = TSV.setup({}, selected.annotation_hash)
        selected.each do |row_key, value|
          matched[row_key] = TSVTasks.copy(value) if [row_key, *Array(value).flatten].join("\t").match?(pattern)
        end
        selected = matched
      end
      case (type || 'double').to_s
      when 'single' then selected.to_single
      when 'list' then selected.to_list
      when 'flat' then selected.to_flat
      else selected
      end
    else
      TSV.open(file, opts)
    end
    table.identifiers = identifiers unless TSVTasks.optional(identifiers)
    table.namespace = namespace unless TSVTasks.optional(namespace)
    unless sep == ','
      table = table.select(select) unless TSVTasks.optional(select)
      table = table.grep(grep) unless TSVTasks.optional(grep)
    end
    wanted = Array(keys).map(&:to_s)
    unless wanted.empty?
      filtered = TSV.setup({}, table.annotation_hash.reject { |n, _| n.to_sym == :filename })
      wanted.uniq.select { |key| table.key?(key) }.sort.each { |key| filtered[key] = TSVTasks.copy(table[key]) }
      table = filtered
    end
    TSVTasks.rename_metadata!(table, key_name: new_key_field, field_names: rename_fields, namespace: namespace, identifiers: identifiers)
    TSVTasks.canonical_render(table)
  end
  export :tsv_read

  desc 'Fetch exact key values in request order.'
  input :file, :path, 'TSV file', nil, required: true
  input :keys, :array, 'Keys to fetch', [], required: true
  input :key_field, :string, 'Override key field', nil
  input :fields, :array, 'Select fields', nil
  input :type, :string, 'TSV type', nil
  input :cast, :string, 'to_i or to_f', nil
  input :column, :string, 'Value field or reserved key', nil
  input :merge, :string, 'Duplicate-key merge', nil
  input :one2one, :boolean, 'Use Scout one2one behavior', false
  input :field, :string, 'Scout convenience field option', nil
  task tsv_query: :json do |file, keys, key_field, fields, type, cast, column, merge, one2one, field|
    TSVTasks.file!(file); TSVTasks.type!(type); TSVTasks.cast!(cast)
    raise ParameterException, 'field and column cannot both be used' unless TSVTasks.optional(field) || TSVTasks.optional(column)
    table = TSV.open(file, TSVTasks.open_options(type: type, key_field: key_field, fields: fields,
      sep: "\t", sep2: '|', header_hash: '#', merge: merge, one2one: one2one, field: field))
    selected = TSVTasks.optional(column) ? nil : column.to_s
    raise ParameterException, 'Named-column queries are unsupported for flat TSVs' if selected && selected != 'key' && table.type.to_sym == :flat
    index = selected && selected != 'key' ? Array(table.fields).map(&:to_s).index(selected) : nil
    raise ParameterException, "Unknown TSV column: #{selected}" if selected && selected != 'key' && index.nil?
    queries = Array(keys).map(&:to_s).map do |key|
      found = table.key?(key)
      value = if !found then nil
              elsif selected == 'key' then key
              elsif index then table.type.to_sym == :single ? table[key] : (table.type.to_sym == :list ? [table[key][index]] : (table.type.to_sym == :double ? table[key][index] : nil))
              else table[key]
              end
      value = selected == 'key' ? value : TSV.cast_value(value, cast.to_sym) if cast && found
      {key: key, found: found, value: value}
    end
    {key_field: table.key_field, fields: table.fields || [], type: table.type, column: selected,
     queries: queries, missing_keys: queries.reject { |q| q[:found] }.map { |q| q[:key] }}
  end
  export :tsv_query

  desc 'Edit one field or a complete row supplied as JSON; type and row shape are validated.'
  input :file, :path, 'TSV file', nil, required: true
  input :key, :string, 'Existing key', nil, required: true
  input :field, :string, 'Field for scalar edit; omit for row replacement', nil
  input :value, :text, 'Replacement value', nil
  input :row, :text, 'Full row JSON replacement', nil
  input :type, :string, 'TSV type override', nil
  extension :tsv
  task tsv_edit: :string do |file, key, field, value, row, type|
    TSVTasks.file!(file); TSVTasks.type!(type)
    row = nil if row == ''
    raise ParameterException, 'specify either row or field/value, not both' if row && field
    raise ParameterException, 'provide a row or both field and value' if !row && (!field || value.nil?)
    table = TSV.open(file, {sep: "\t", sep2: '|', header_hash: '#', persist: false}.tap { |opts| opts[:type] = type.to_sym unless TSVTasks.optional(type) })
    kind = table.type.to_sym
    raise ParameterException, "Unknown TSV key: #{key}" unless table.key?(key.to_s)
    names = Array(table.fields).map(&:to_s)
    if row
      table[key.to_s] = TSVTasks.validate_row(kind, TSVTasks.json_row(row), names.length)
    else
      raise ParameterException, 'Named-field edit is unsafe for flat TSV' if kind == :flat
      idx = names.index(field.to_s)
      raise ParameterException, "Unknown TSV field: #{field}" if idx.nil?
      raise ParameterException, 'replacement value cannot contain tabs/newlines' if value.to_s.match?(/[\t\r\n]/)
      case kind
      when :single
        raise ParameterException, 'single TSV requires exactly one value field' unless names.length == 1 && idx.zero?
        table[key.to_s] = value.to_s
      when :list
        current = table[key.to_s]
        raise ParameterException, 'malformed list row' unless current.is_a?(Array) && current.length == names.length
        updated = current.dup; updated[idx] = value.to_s; table[key.to_s] = updated
      when :double
        current = table[key.to_s]
        raise ParameterException, 'malformed double row' unless current.is_a?(Array) && current.length == names.length && current.all? { |cell| cell.is_a?(Array) }
        updated = TSVTasks.copy(current); updated[idx] = value.to_s.empty? ? [] : value.to_s.split('|', -1); table[key.to_s] = updated
      end
    end
    text = TSVTasks.render(table)
    TSVTasks.replace_source!(file, text)
    text
  end
  export :tsv_edit

  desc 'Merge compatible TSV tables; replace delegates to TSV#merge (right wins), zip delegates to TSV#merge_zip for double tables.'
  input :left, :path, 'Left TSV', nil, required: true
  input :right, :path, 'Right TSV', nil, required: true
  input :strategy, :string, 'replace or zip', 'replace'
  extension :tsv
  task tsv_merge: :string do |left, right, strategy|
    [left, right].each { |path| TSVTasks.file!(path) }
    raise ParameterException, 'strategy must be replace or zip' unless %w[replace zip].include?(strategy.to_s)
    opts = {sep: "\t", sep2: '|', header_hash: '#', persist: false}
    l = TSV.open(left, opts.dup); r = TSV.open(right, opts.dup)
    %i[key_field fields type].each { |attr| raise ParameterException, "TSV #{attr} conflict" unless l.public_send(attr) == r.public_send(attr) }
    metadata = %i[namespace identifiers serializer entity_options]
    conflicts = metadata.select { |name| l.public_send(name) != r.public_send(name) }
    raise ParameterException, "TSV annotation metadata conflict: #{conflicts.join(', ')}" unless conflicts.empty?
    raise ParameterException, 'zip is supported only for double TSVs' if strategy.to_s == 'zip' && l.type.to_sym != :double
    result = if strategy.to_s == 'replace'
      TSVTasks.right_replacement(l, r)
    else
      TSVTasks.clone_table(l).tap { |merged| r.each { |key, value| merged.zip_new(key, TSVTasks.copy(value)) } }
    end
    TSVTasks.canonical_render(result)
  end
  export :tsv_merge

  desc 'Attach right-side TSV fields on exact matches with TSV.attach, using a copy because that API mutates its source.'
  input :source, :path, 'Source TSV', nil, required: true
  input :other, :path, 'Right TSV', nil, required: true
  input :match_key, :string, 'Source key or field', nil, required: true
  input :other_key, :string, 'Right key or field', nil, required: true
  input :fields, :array, 'Right-side value fields (default non-key fields)', nil
  input :one2one, :boolean, 'Use one2one behavior', true
  extension :tsv
  task tsv_attach: :string do |source, other, match_key, other_key, fields, one2one|
    [source, other].each { |path| TSVTasks.file!(path) }
    opts = {sep: "\t", sep2: '|', header_hash: '#', persist: false}
    src = TSV.open(source, opts.dup); rhs = TSV.open(other, opts.dup)
    raise ParameterException, 'flat TSVs cannot be attached' if [src, rhs].any? { |table| table.type.to_sym == :flat }
    sp = src.identify_field(match_key.to_s); rp = rhs.identify_field(other_key.to_s)
    raise ParameterException, "Unknown source match field: #{match_key}" if sp.nil?
    raise ParameterException, "Unknown right match field: #{other_key}" if rp.nil?
    source_name = sp == :key ? src.key_field : src.fields[sp]
    right_name = rp == :key ? rhs.key_field : rhs.fields[rp]
    raise ParameterException, 'right value matching requires list/double TSV' if rp != :key && %i[single flat].include?(rhs.type.to_sym)
    chosen = TSVTasks.optional(fields) ? (rhs.fields || []).map(&:to_s) - [right_name.to_s] : Array(fields).map(&:to_s)
    raise ParameterException, 'No right fields selected' if chosen.empty?
    chosen.each { |name| raise ParameterException, "Unknown right field: #{name}" if rhs.identify_field(name).nil? || rhs.identify_field(name) == :key }
    collisions = chosen & Array(src.fields).map(&:to_s)
    raise ParameterException, "Attached fields conflict with source fields: #{collisions.join(', ')}" unless collisions.empty?
    matches = rp == :key ? rhs.keys : rhs.values.flat_map { |record| value = record[rp]; value.is_a?(Array) ? value : [value] }
    raise ParameterException, 'Repeated right-side match values are unsupported' unless matches.compact.uniq.length == matches.compact.length
    result = TSVTasks.clone_table(src)
    reordered = rhs.reorder(other_key.to_s, chosen, one2one: one2one, type: :double)
    reordered.key_field = source_name
    TSV.attach(result, reordered, match_key: source_name, other_key: :key, fields: chosen,
      one2one: one2one, complete: false, insitu: false)
    TSVTasks.canonical_render(result)
  end
  export :tsv_attach

  desc 'Translate a TSV key or value field with TSV.translate and an explicit identifier mapping.'
  input :file, :path, 'TSV file', nil, required: true
  input :field, :string, 'Key or value field', nil, required: true
  input :target_format, :string, 'Target identifier format', nil, required: true
  input :identifiers, :path, 'Identifier mapping TSV', nil, required: true
  input :type, :string, 'TSV type override', nil
  input :key_field, :string, 'Key-field override', nil
  input :fields, :array, 'Value-field selection', nil
  input :one2one, :boolean, 'Use one2one behavior', false
  extension :tsv
  task tsv_translate: :string do |file, field, target_format, identifiers, type, key_field, fields, one2one|
    [file, identifiers].each { |path| TSVTasks.file!(path) }; TSVTasks.type!(type)
    opts = {sep: "\t", sep2: '|', header_hash: '#', persist: false}
    opts[:type] = type.to_sym unless TSVTasks.optional(type)
    opts[:key_field] = key_field unless TSVTasks.optional(key_field)
    opts[:fields] = fields unless TSVTasks.optional(fields)
    table = TSV.open(file, opts)
    translated = TSV.translate(table, field.to_s, target_format.to_s,
      identifiers: identifiers, one2one: one2one, persist_index: false)
    TSVTasks.canonical_render(translated)
  end
  export :tsv_translate
end

ComputerUse.export :tsv_info, :tsv_read, :tsv_query, :tsv_edit, :tsv_merge, :tsv_attach, :tsv_translate

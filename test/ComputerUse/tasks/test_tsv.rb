require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path('../../../workflow', __dir__)
require 'tmpdir'

class TestComputerUseTSV < Test::Unit::TestCase
  def with_tsv(content, name = 'source.tsv')
    Dir.mktmpdir('computeruse-tsv') do |dir|
      path = File.join(dir, name)
      File.binwrite(path, content)
      yield path, dir
    end
  end

  def job(name, **inputs)
    ComputerUse.job(name, nil, inputs)
  end

  def read_job(name, file, **inputs)
    job(name, file: file, **inputs)
  end

  def tsv_text(type: 'double', fields: "#ID\tGene\tScore", rows: "A\tTP53|BRCA1\t1|2\n")
    "#: :type=:#{type}\n#{fields}\n#{rows}"
  end

  def run_with_harness_return_path(name, **inputs)
    expected = job(name, **inputs).path.to_s
    path = LLM.call_workflow(ComputerUse, name, inputs.merge(return_path: true)).to_s
    assert(File.file?(path), 'harness return_path points to the persisted job result')
    assert_equal File.expand_path(expected), File.expand_path(path)
    path
  end


  def test_task_surface_is_consolidated_and_harness_owns_return_path
    names = ComputerUse.tasks.keys.grep(/\Atsv_/).map(&:to_sym).sort
    assert_equal %i[tsv_attach tsv_edit tsv_info tsv_merge tsv_query tsv_read tsv_sort tsv_translate], names
    names.each do |name|
      inputs = ComputerUse.tasks[name].inputs.map { |input| input.respond_to?(:name) ? input.name : input }
      assert_not_include inputs, :return_path, "#{name} must not declare the harness option as a task input"
    end
    %i[tsv_query tsv_edit tsv_merge tsv_attach tsv_translate].each do |name|
      inputs = ComputerUse.tasks[name].inputs.map { |input| input.respond_to?(:name) ? input.name : input }
      assert_empty(%i[sep sep2 header_hash] & inputs, "#{name} consumes prepared Scout TSV")
    end
    tool = LLM.task_tool_definition(ComputerUse, :tsv_read)
    assert_include tool[:parameters][:properties].keys.map(&:to_sym), :return_path
    assert_equal 'boolean', tool[:parameters][:properties][:return_path][:type].to_s
  end

  def inputs_for(name)
    ComputerUse.tasks[name].inputs.map { |input| input.respond_to?(:name) ? input.name : input }
  end

  def test harness_option_is_extracted_not_an_input_on_persistent_result_workflow_task
    source = File.read(File.join(Gem.loaded_specs['scout-ai'].full_gem_path, 'lib/scout/llm/tools/workflow.rb'))
    assert_match(/process_options parameters, :jobname, :return_path, :exec_type, :allow_recursive/, source)
    assert_match(/if return_path\s+job\.run\(true\).*?job\.path/m, source)
    refute_includes inputs_for(:tsv_read), :return_path
  end

  def test_info_reports_shape_and_entity_format_candidates
    with_tsv("#: :type=:double\n#ID\tGene\tScore\nA\tTP53|BRCA1\t1|2\n") do |file, _dir|
      result = read_job(:tsv_info, file).run
      assert_equal 'ID', result[:key_field]
      assert_equal %w[Gene Score], result[:fields]
      assert_equal :double, result[:type]
      assert_equal 1, result[:source_rows]
      assert_equal 1, result[:unique_keys]
      assert_equal [], result[:entity_field_candidates]
    end
  end

  def test_merge_false_keeps_last_duplicate_key_row_in_read_and_info
    with_tsv("#: :type=:double\n#ID\tScore\nA\tfirst\nA\tlast\n") do |file, _dir|
      read = read_job(:tsv_read, file, merge: 'false').run
      table = TSV.open(StringIO.new(read), persist: false)
      assert_equal ['A'], table.keys
      assert_equal [%w[last]], table['A']

      info = read_job(:tsv_info, file, merge: 'false', new_type: 'double').run
      assert_equal 1, info[:source_rows]
      assert_equal 1, info[:unique_keys]
      assert_equal [%w[last]], TSV.open(file, persist: false)['A']
    end
  end

  def test_read_returns_scout_tsv_text_and_supports_csv_empty_header_hash
    with_tsv("ID,Gene\nA,TP53\n", 'source.csv') do |file, _dir|
      read = read_job(:tsv_read, file, type: 'single', sep: ',', header_hash: '').run
      assert_kind_of String, read
      table = TSV.open(StringIO.new(read), persist: false)
      assert_equal :single, table.type
      assert_equal %w[Gene], table.fields
      assert_match(/#ID\tGene\nA\tTP53\n\z/, read)

      output = run_with_harness_return_path(:tsv_read, file: file, type: 'single', sep: ',', header_hash: '')
      assert_equal read, File.binread(output)
    end
  end

  def test_read_supports_scout_open_options_and_exact_key_subset
    with_tsv("#: :type=:single\n#ID\tScore\nA\t01\nB\t02\n") do |file, _dir|
      text = read_job(:tsv_read, file, type: 'single', keys: ['B'], cast: 'to_i').run
      subset = TSV.open(StringIO.new(text), persist: false)
      assert_equal ['B'], subset.keys
      assert_equal 2, subset['B']
    end
  end

  def test_prepared_tsv_is_consumed_by_query_using_canonical_defaults
    with_tsv("ID,Score\nA,12|13\n", 'source.csv') do |csv, dir|
      prepared = read_job(:tsv_read, csv, type: 'double', sep: ',', header_hash: '').run
      canonical = File.join(dir, 'prepared.tsv')
      File.write(canonical, prepared)
      result = read_job(:tsv_query, canonical, keys: ['A']).run
      assert_equal 'ID', result[:key_field]
      assert_equal %w[Score], result[:fields]
      assert_equal [['12', '13']], result[:queries].first[:value]
    end
  end

  def test_query_returns_request_order_missing_keys_and_recursively_casts_without_column
    with_tsv("#: :type=:double\n#ID\tScore\nA\t12|13\nB\t20\n") do |file, _dir|
      result = read_job(:tsv_query, file, keys: %w[B missing A], cast: 'to_i').run
      assert_equal %w[B missing A], result[:queries].map { |entry| entry[:key] }
      assert_equal [[[20]], nil, [[12, 13]]], result[:queries].map { |entry| entry[:value] }
      assert_equal ['missing'], result[:missing_keys]

      selected = read_job(:tsv_query, file, keys: ['A'], column: 'key', cast: 'to_i').run
      assert_equal 'A', selected[:queries].first[:value]

      list_file = File.join(File.dirname(file), 'list.tsv')
      File.write(list_file, "#: :type=:list\n#ID\tGene\tScore\nA\tTP53\t7\n")
      list_query = read_job(:tsv_query, list_file, keys: ['A'], column: 'Score').run
      assert_equal ['7'], list_query[:queries].first[:value]
    end
  end

  def test_query_rejects_invalid_cast_and_unknown_field
    with_tsv("#: :type=:single\n#ID\tScore\nA\t12\n") do |file, _dir|
      assert_raise(ParameterException) { read_job(:tsv_query, file, keys: ['A'], cast: 'to_s').run }
      assert_raise(ParameterException) { read_job(:tsv_query, file, keys: ['A'], column: 'Other').run }
    end
  end

  def test_edit_field_and_full_row_mutate_source_and_return_updated_output
    with_tsv("#: :type=:double\n#ID\tGene\tScore\nA\tTP53|BRCA1\t1|2\n") do |file, _dir|
      field_output = run_with_harness_return_path(:tsv_edit, file: file, key: 'A', field: 'Gene', value: 'MYC|ALK')
      assert_equal [%w[MYC ALK], %w[1 2]], TSV.open(file, persist: false)['A']
      assert_equal File.binread(file), File.binread(field_output)

      row_output = run_with_harness_return_path(:tsv_edit, file: file, key: 'A', row: '[["EGFR"], ["7", "8"]]')
      reopened = TSV.open(file, persist: false)
      assert_equal [%w[EGFR], %w[7 8]], reopened['A']
      assert_equal :double, reopened.type
      assert_equal %w[Gene Score], reopened.fields
      assert_equal File.binread(file), File.binread(row_output)
    end
  end

  def test_info_persists_renamed_fields_namespace_and_identifier_path
    with_tsv("#: :type=:list\n#ID\tGene\tScore\nA\tTP53\t7\n") do |file, _dir|
      identifiers = File.join(File.dirname(file), 'ids.tsv')
      result = read_job(:tsv_info, file, new_key_field: 'Sample', rename_fields: %w[Symbol Rank],
                        namespace: 'test', identifiers: identifiers).run
      assert_equal 'Sample', result[:key_field]
      assert_equal %w[Symbol Rank], result[:fields]
      assert_equal 'test', result[:namespace]
      assert_equal identifiers, result[:identifiers]
      reopened = TSV.open(file, persist: false)
      assert_equal 'test', reopened.namespace
      assert_equal identifiers, reopened.identifiers
      assert_equal 'Sample', reopened.key_field
      assert_equal %w[Symbol Rank], reopened.fields
      assert_equal 'list', reopened.type.to_s
      assert_equal ['TP53', '7'], reopened['A']
    end
  end

  def test_info_persists_cast_type_and_combined_metadata_updates
    with_tsv("#: :type=:list\n#ID\tGene\tScore\nA\tTP53\t7\n") do |file, dir|
      identifiers = File.join(dir, 'mapping.tsv')
      result = read_job(:tsv_info, file, new_key_field: 'Sample', rename_fields: %w[Symbol Rank],
                        cast: 'to_i', new_type: 'double', namespace: 'study',
                        identifiers: identifiers).run
      assert_equal 'Sample', result[:key_field]
      assert_equal %w[Symbol Rank], result[:fields]
      assert_equal :double, result[:type]
      assert_equal 'to_i', result[:cast].to_s
      assert_equal 'study', result[:namespace]
      assert_equal identifiers, result[:identifiers]

      reopened = TSV.open(file, persist: false)
      assert_equal 'Sample', reopened.key_field
      assert_equal %w[Symbol Rank], reopened.fields
      assert_equal :double, reopened.type
      assert_equal :to_i, reopened.cast
      assert_equal 'study', reopened.namespace
      assert_equal identifiers, reopened.identifiers
      assert_equal [[0], [7]], reopened['A']
    end
  end

  def test_info_validates_persistent_cast_and_type_before_replacing_source
    with_tsv("#: :type=:single\n#ID\tScore\nA\t12\n") do |file, _dir|
      before = File.binread(file)
      assert_raise(ParameterException) { read_job(:tsv_info, file, cast: 'to_s').run }
      assert_equal before, File.binread(file)
      assert_raise(ParameterException) { read_job(:tsv_info, file, new_type: 'triple').run }
      assert_equal before, File.binread(file)
    end
  end

  def test_source_mutations_reject_read_only_files
    with_tsv("#: :type=:single\n#ID\tScore\nA\t12\n") do |file, _dir|
      original_mode = File.stat(file).mode & 0o777
      before = File.binread(file)
      File.chmod(0o444, file)
      assert_raise(ParameterException) { read_job(:tsv_edit, file, key: 'A', field: 'Score', value: '13').run }
      assert_equal before, File.binread(file)
      assert_raise(ParameterException) { read_job(:tsv_info, file, new_key_field: 'Sample').run }
      assert_equal before, File.binread(file)
    ensure
      File.chmod(original_mode, file) if original_mode
    end
  end

  def test_source_mutations_reject_symlink_inputs_without_touching_target
    with_tsv("#: :type=:single\n#ID\tScore\nA\t12\n", 'target.tsv') do |target, dir|
      link = File.join(dir, 'source-link.tsv')
      File.symlink(target, link)
      before = File.binread(target)
      assert_raise(ParameterException) { read_job(:tsv_edit, link, key: 'A', field: 'Score', value: '13').run }
      assert_equal before, File.binread(target)
    end
  end

  def test_invalid_edit_never_changes_source_or_materializes_an_output
    with_tsv("#: :type=:list\n#ID\tGene\tScore\nA\tTP53\t7\n") do |file, _dir|
      before = File.binread(file)
      assert_raise(ParameterException) do
        read_job(:tsv_edit, file, key: 'A', row: '["bad"]').run
      end
      assert_equal before, File.binread(file)
    end
  end

  def test_edit_validates_row_shapes_missing_keys_fields_and_flat_field_edits
    with_tsv("#: :type=:list\n#ID\tGene\tScore\nA\tTP53\t7\n") do |file, _dir|
      before = File.binread(file)
      assert_raise(ParameterException) { read_job(:tsv_edit, file, key: 'A', row: '["only-one"]').run }
      assert_equal before, File.binread(file)
      assert_raise(ParameterException) { read_job(:tsv_edit, file, key: 'A', field: 'Missing', value: 'x').run }
      assert_equal before, File.binread(file)
      assert_raise(ParameterException) { read_job(:tsv_edit, file, key: 'absent', field: 'Gene', value: 'x').run }
      assert_equal before, File.binread(file)
    end
    with_tsv("#: :type=:flat\n#ID\tGene\nA\tTP53|BRCA1\n") do |file, _dir|
      assert_raise(ParameterException) { read_job(:tsv_edit, file, key: 'A', field: 'Gene', value: 'x').run }
      output = run_with_harness_return_path(:tsv_edit, file: file, key: 'A', row: '["EGFR", "MYC"]')
      assert_equal %w[EGFR MYC], TSV.open(output, persist: false)['A']
      assert_equal %w[EGFR MYC], TSV.open(file, persist: false)['A']
    end
  end

  def test_read_rejects_unusable_source_write_for_info_override_and_edit
    with_tsv("#: :type=:single\n#ID\tScore\nA\t12\n") do |file, dir|
      # Directory permissions are checked explicitly; simulate an unusable directory
      # through a symlink source, which is rejected consistently even when tests run as root.
      link = File.join(dir, 'source-link.tsv')
      File.symlink(file, link)
      assert_raise(ParameterException) { read_job(:tsv_info, link, new_key_field: 'Sample').run }
      assert_raise(ParameterException) { read_job(:tsv_edit, link, key: 'A', field: 'Score', value: '13').run }
    end
  end

  def test_merge_replaces_entire_colliding_row_or_explicitly_zips_double_values
    with_tsv("#: :type=:double\n#ID\tGene\tScore\nA\tLEFT\t1\nB\tONLY_LEFT\t2\n", 'left.tsv') do |left, dir|
      right = File.join(dir, 'right.tsv')
      File.write(right, "#: :type=:double\n#ID\tGene\tScore\nA\tRIGHT\t3\nC\tONLY_RIGHT\t4\n")
      replace_path = run_with_harness_return_path(:tsv_merge, left: left, right: right, strategy: 'replace')
      replaced = TSV.open(replace_path, persist: false)
      assert_equal [%w[RIGHT], %w[3]], replaced['A']
      assert_equal [%w[ONLY_LEFT], %w[2]], replaced['B']
      assert_equal [%w[ONLY_RIGHT], %w[4]], replaced['C']

      zip_path = run_with_harness_return_path(:tsv_merge, left: left, right: right, strategy: 'zip')
      zipped = TSV.open(zip_path, persist: false)
      assert_equal [%w[LEFT RIGHT], %w[1 3]], zipped['A']
      assert_equal "#: :type=:double\n#ID\tGene\tScore\nA\tLEFT\t1\nB\tONLY_LEFT\t2\n", File.read(left)
    end
  end

  def test_attach_copies_source_and_harness_can_return_job_path
    with_tsv("#: :type=:double\n#ID\tGene\nA\tTP53\nB\tBRCA1\n", 'source.tsv') do |source, dir|
      other = File.join(dir, 'other.tsv')
      File.write(other, "#: :type=:double\n#ID\tGene\tRank\nX\tTP53\t1\n")
      before = File.binread(source)
      path = run_with_harness_return_path(:tsv_attach, source: source, other: other,
                                          match_key: 'Gene', other_key: 'Gene')
      attached = TSV.open(path, persist: false)
      assert_equal %w[Gene Rank], attached.fields
      assert_equal [%w[TP53], %w[1]], attached['A']
      assert_equal [%w[BRCA1], []], attached['B']
      assert_equal before, File.binread(source)
    end
  end


  def test_sort_by_numeric_field_pages_and_returns_keys_or_tsv
    with_tsv("#: :type=:double\n#ID\tScore\tGene\nA\t10\tAlpha\nB\t2\tBeta\nC\t30\tGamma\n") do |file, _dir|
      keys = read_job(:tsv_sort, file, column: 'Score', cast: 'to_i', page: 1, page_size: 2, just_keys: true).run
      assert_equal %w[B A], keys[:keys]
      assert_equal 3, keys[:total_keys]

      floats = read_job(:tsv_sort, file, column: 'Score', cast: 'to_f', page: 1, page_size: 2, just_keys: true).run
      assert_equal %w[B A], floats[:keys]

      page = read_job(:tsv_sort, file, column: 'Score', cast: 'to_i', direction: 'descending', page: 2, page_size: 2).run
      table = TSV.open(StringIO.new(page[:tsv]), persist: false)
      assert_equal ['B'], table.keys
      assert_equal %w[Score Gene], table.fields
      assert_equal ['2'], table['B'][0]

      all_keys = read_job(:tsv_sort, file, column: 'key', just_keys: true).run
      assert_equal %w[A B C], all_keys[:keys]
    end
  end

  def test_sort_validates_column_cast_direction_and_pagination
    with_tsv("#: :type=:single\n#ID\tScore\nA\t12\n") do |file, _dir|
      assert_raise(ParameterException) { read_job(:tsv_sort, file, column: 'Other').run }
      assert_raise(ParameterException) { read_job(:tsv_sort, file, cast: 'to_s').run }
      assert_raise(ParameterException) { read_job(:tsv_sort, file, direction: 'sideways').run }
      assert_raise(ParameterException) { read_job(:tsv_sort, file, page: 0).run }
      assert_raise(ParameterException) { read_job(:tsv_sort, file, page_size: 0).run }
      empty_page = read_job(:tsv_sort, file, page: 3, page_size: 1, just_keys: true).run
      assert_equal [], empty_page[:keys]
    end
  end

  def test_sort_float_cast_and_full_tsv_preserve_sorted_key_order
    with_tsv("#: :type=:double\n#ID\tScore\tTags\nA\t10.1\ta|b\nB\t2.2\tc\nC\t1.5\td\n") do |file, _dir|
      keys = read_job(:tsv_sort, file, column: 'Score', cast: 'to_f', just_keys: true).run
      assert_equal %w[C B A], keys[:keys]

      page = read_job(:tsv_sort, file, column: 'Score', cast: 'to_f').run
      table = TSV.open(StringIO.new(page[:tsv]), persist: false)
      assert_equal %w[C B A], table.keys
      assert_equal ['d'], table['C'][1]
    end
  end

  def test_translate_values_through_identifiers_and_harness_returns_job_path
    with_tsv("#: :type=:double\n#ID\tGene\nA\tTP53|BRCA1\n", 'source.tsv') do |file, dir|
      identifiers = File.join(dir, 'identifiers.tsv')
      File.write(identifiers, "#Gene\tAccession\nTP53\tP04637\nBRCA1\tP38398\n")
      before = File.binread(file)
      output = run_with_harness_return_path(:tsv_translate, file: file, field: 'Gene',
                                            target_format: 'Accession', identifiers: identifiers)
      translated = TSV.open(output, persist: false)
      assert_equal 'Accession', translated.fields.first
      assert_equal %w[P04637 P38398], translated['A'].first
      assert_equal before, File.binread(file)
    end
  end
end

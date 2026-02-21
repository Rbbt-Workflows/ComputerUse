module ComputerUse
  require 'fileutils'
  require 'shellwords'

  # Required: the URL the test should visit (e.g. http://localhost:3000)
  input :url, :string, 'URL to test (e.g. http://localhost:3000)', nil, required: true

  input :code, :text, 'Playwright test code to run (JS/TS). If provided the code will be saved to .playwright/scripts and executed', nil
  input :file, :path, 'Path to an existing Playwright test file to execute. If provided, this file is used instead of inline code', nil

  input :headless, :boolean, 'Run browser headlessly (default: true)', true
  input :trace, :boolean, 'Enable Playwright tracing for the run (default: false)', false
  input :video, :boolean, 'Enable video recording for tests (default: false)', false
  input :timeout, :integer, 'Per-test timeout in seconds (default: 10)', 10
  input :extra_args, :string, 'Extra arguments to pass to `playwright test` (optional)', nil

  extension :json
  task :playwright => :text do |url, code, file, headless, trace, video, timeout, extra_args|
    raise ParameterException, 'url is required' if url.nil? || url.to_s.strip.empty?

    # Normalize booleans and values
    headless = (headless.nil? ? true : !!headless)
    trace = !!trace
    video = !!video
    timeout = (timeout || 300).to_i
    extra_args = extra_args.to_s.strip

    cwd = Dir.pwd
    scripts_dir = File.join(cwd, '.playwright', 'scripts')
    base_runs_dir = File.join(cwd, '.playwright', 'runs')
    timestamp = Time.now.strftime('%Y%m%dT%H%M%S')
    run_dir = File.join(base_runs_dir, timestamp + "_#{Process.pid}_#{rand(9999)}")

    FileUtils.mkdir_p(scripts_dir)
    FileUtils.mkdir_p(run_dir)

    # Determine test file to run
    test_path = nil
    if file && !file.to_s.strip.empty?
      # Use provided file path (absolute or relative)
      test_path = File.expand_path(file.to_s, cwd)
      unless File.exist?(test_path)
        raise ParameterException, "Provided test file not found: #{file}"
      end
    elsif code && !code.to_s.strip.empty?
      # Write inline code to a generated script under .playwright/scripts
      fname = "generated_#{Time.now.to_i}_#{rand(9999)}.spec.js"
      test_path = File.join(scripts_dir, fname)
      File.write(test_path, code)
    else
      # Create a minimal default test that navigates to the URL and does a basic smoke check
      fname = "default_#{Time.now.to_i}_#{rand(9999)}.js"
      test_path = File.join(scripts_dir, fname)
      default_code = <<~JS
        const { chromium } = require('playwright');

        (async () => {
          const browser = await chromium.launch();
          const page = await browser.newPage();
          await page.goto(process.env.PLAYWRIGHT_TEST_URL || '#{url}', { waitUntil: 'load' });
          const hasHtmx = await page.evaluate(() => {
            if (typeof window !== 'undefined' && window.htmx) return true;
            const scripts = Array.from(document.querySelectorAll('script')).map(s => s.src || '');
            if (scripts.some(src => src.includes('htmx'))) return true;
            return !!document.querySelector('[hx-get],[hx-post],[hx-swap],[hx-trigger],[hx-target]');
          });
          console.log('HTMX_PRESENT:' + (hasHtmx ? '1' : '0'));
          await browser.close();
          process.exit(hasHtmx ? 0 : 2);
        })().catch(e => { console.error(e); process.exit(1); });
      JS
      File.write(test_path, default_code)
    end

    # Read the test file to decide runner type. If it uses @playwright/test we'll run via `npx playwright test`.
    test_content = File.read(test_path) rescue ''
    use_test_runner = !!(test_content =~ /@playwright\/test/)

    # Default reporters (only used with test runner)
    report_json = File.join(run_dir, 'report.json')
    html_report_dir = File.join(run_dir, 'html-report')

    # Ensure URL is provided to the test via environment variable
    env_prefix = "PLAYWRIGHT_TEST_URL=#{Shellwords.escape(url)}"

    if use_test_runner
      # Build individual reporter args (safer than a single comma-separated reporter)
      reporter_args = []
      reporter_args << "--reporter=json=#{Shellwords.escape(report_json)}"
      reporter_args << "--reporter=html=#{Shellwords.escape(html_report_dir)}"
      reporter_args << "--reporter=line"

      # Build playwright test command
      timeout_ms = (timeout * 1000).to_i

      cmd = []
      cmd << env_prefix
      cmd << 'npx'
      cmd << '--no-install'
      cmd << 'playwright'
      cmd << 'test'
      cmd << Shellwords.escape(test_path)
      cmd.concat(reporter_args)
      cmd << "--timeout=#{timeout_ms}"
      cmd << '--trace=on' if trace
      cmd << '--video=on' if video
      cmd << '--headed' unless headless
      cmd << extra_args unless extra_args.empty?

      full_cmd = cmd.join(' ')

      # Run using the sandbox_run helper. Expose writable dirs so artifacts are accessible.
      writable_dirs = [scripts_dir, run_dir, cwd]
      res = sandbox_run(:bash, ['-c', full_cmd], {}, writable_dirs)

    else
      # Run as a standalone node script (uses playwright library directly)
      cmd = []
      cmd << env_prefix
      cmd << 'node'
      cmd << Shellwords.escape(test_path)
      full_cmd = cmd.join(' ')

      writable_dirs = [scripts_dir, run_dir, cwd]
      res = sandbox_run(:bash, ['-c', full_cmd], {}, writable_dirs)
    end

    # Locate html index if present (only meaningful for test runner run)
    html_index = nil
    index_path = File.join(html_report_dir, 'index.html')
    if File.exist?(index_path)
      html_index = index_path
      begin
        # set tmp_path to the html index for convenience (if supported by the workflow base)
        self.tmp_path = html_index if respond_to?(:tmp_path)
      rescue
        # ignore if not applicable
      end
    end

    {
      stdout: res[:stdout].to_s,
      stderr: res[:stderr].to_s,
      exit_status: res[:exit_status].to_i,
      results_dir: run_dir,
      report_json: File.exist?(report_json) ? report_json : nil,
      html_report_dir: File.directory?(html_report_dir) ? html_report_dir : nil,
      html_index: html_index
    }
  end

  export_exec :playwright
end

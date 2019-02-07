# encoding: utf-8

require 'inspec/profile_vendor'
require 'mixlib/shellout'
require 'tomlrb'
require 'ostruct'

module InspecPlugins
  module Habitat
    class Profile
      def initialize(path, options = {})
        @path = path
        @options = options

        log_level = options.fetch(:log_level, 'info')
        @log = Inspec::Log
        @log.level(log_level.to_sym)
      end

      def create
        @log.info("Creating a Habitat artifact for '#{@path}'")
        working_dir = create_working_dir
        habitat_config = read_habitat_config

        output_dir = @options[:output_dir] || Dir.pwd
        unless File.directory?(output_dir)
          exit_with_error("Output directory #{output_dir} is not a directory " \
                          'or does not exist.')
        end

        verify_habitat_setup(habitat_config)

        duplicated_profile = duplicate_profile(@path, working_dir)
        prepare_profile!(duplicated_profile)

        hart_file = build_hart(working_dir, habitat_config)

        @log.info("Copying artifact to #{output_dir}...")
        destination = File.join(output_dir, File.basename(hart_file))
        FileUtils.cp(hart_file, destination)

        destination
      rescue => e
        @log.debug(e.backtrace.join("\n"))
        exit_with_error(
          'Unable to create Habitat artifact.',
          "#{e.class} -- #{e.message}",
        )
      ensure
        @log.debug("Deleting working directory #{working_dir}")
        FileUtils.rm_rf(working_dir)
      end

      def setup(profile = profile_from_path(@path))
        path = profile.root_path
        @log.info("Setting up #{path} for Habitat...")

        plan_file = File.join(path, 'habitat', 'plan.sh')
        @log.info("Generating Habitat plan at #{plan_file}...")
        vars = {
          profile: profile,
          habitat_origin: read_habitat_config['origin'],
        }
        create_file_from_template(plan_file, 'plan.sh.erb', vars)

        run_hook_file = File.join(path, 'habitat', 'hooks', 'run')
        @log.info("Generating a Habitat run hook at #{run_hook_file}...")
        create_file_from_template(run_hook_file, 'hooks/run.erb')

        default_toml = File.join(path, 'habitat', 'default.toml')
        @log.info("Generating a Habitat default.toml at #{default_toml}...")
        create_file_from_template(default_toml, 'default.toml.erb')

        config = File.join(path, 'habitat', 'config', 'inspec_exec_config.json')
        @log.info("Generating #{config} for `inspec exec`...")
        create_file_from_template(config, 'config/inspec_exec_config.json.erb')
      end

      def upload
        habitat_config = read_habitat_config

        if habitat_config['auth_token'].nil?
          exit_with_error(
            'Unable to determine Habitat auth token for uploading.',
            'Run `hab setup` or set the HAB_AUTH_TOKEN environment variable.',
          )
        end

        # Run create command to create habitat artifact
        hart = create

        @log.info("Uploading Habitat artifact #{hart}")
        upload_hart(hart, habitat_config)
      rescue => e
        @log.debug(e.backtrace.join("\n"))
        exit_with_error(
          'Unable to upload Habitat artifact.',
          "#{e.class} -- #{e.message}",
        )
      end

      private

      def create_working_dir
        working_dir = Dir.mktmpdir
        @log.debug("Generated working directory #{working_dir}")
        working_dir
      end

      def duplicate_profile(path, working_dir)
        profile = profile_from_path(path)
        copy_profile_to_working_dir(profile, working_dir)
        profile_from_path(working_dir)
      end

      def prepare_profile!(profile)
        vendored_profile = vendor_profile_dependencies!(profile)
        verify_profile(vendored_profile)
        setup(vendored_profile)
      end

      def profile_from_path(path)
        Inspec::Profile.for_target(
          path,
          backend: Inspec::Backend.create(Inspec::Config.mock),
        )
      end

      def copy_profile_to_working_dir(profile, working_dir)
        @log.info('Copying profile contents to the working directory...')
        profile.files.each do |profile_file|
          next if File.extname(profile_file) == '.hart'

          src = File.join(profile.root_path, profile_file)
          dst = File.join(working_dir, profile_file)
          if File.directory?(profile_file)
            @log.debug("Creating directory #{dst}")
            FileUtils.mkdir_p(dst)
          else
            @log.debug("Copying file #{src} to #{dst}")
            FileUtils.cp_r(src, dst)
          end
        end
      end

      def verify_profile(profile)
        @log.info('Checking to see if the profile is valid...')

        unless profile.check[:summary][:valid]
          exit_with_error('Profile check failed. Please fix the profile ' \
                          'before creating a Habitat artifact.')
        end

        @log.info('Profile is valid.')
      end

      def vendor_profile_dependencies!(profile)
        profile_vendor = Inspec::ProfileVendor.new(profile.root_path)
        if profile_vendor.lockfile.exist? && profile_vendor.cache_path.exist?
          @log.info("Profile's dependencies are already vendored, skipping " \
                    'vendor process.')
        else
          @log.info("Vendoring the profile's dependencies...")
          profile_vendor.vendor!

          @log.info('Ensuring all vendored content has read permissions...')
          profile_vendor.make_readable
        end

        # Return new profile since it has changed
        Inspec::Profile.for_target(
          profile.root_path,
          backend: Inspec::Backend.create(Inspec::Config.mock),
        )
      end

      def verify_habitat_setup(habitat_config)
        @log.info('Checking to see if Habitat is installed...')
        cmd = Mixlib::ShellOut.new('hab --version')
        cmd.run_command
        if cmd.error?
          exit_with_error('Unable to run Habitat commands.', cmd.stderr)
        end

        if habitat_config['origin'].nil?
          exit_with_error(
            'Unable to determine Habitat origin name.',
            'Run `hab setup` or set the HAB_ORIGIN environment variable.',
          )
        end
      end

      def create_file_from_template(file, template, vars = {})
        FileUtils.mkdir_p(File.dirname(file))
        template_path = File.join(__dir__, '../../templates/habitat', template)
        contents = ERB.new(File.read(template_path))
                      .result(OpenStruct.new(vars).instance_eval { binding })
        File.write(file, contents)
      end

      def build_hart(working_dir, habitat_config)
        @log.info('Building our Habitat artifact...')

        env = {
          'TERM'               => 'vt100',
          'HAB_ORIGIN'         => habitat_config['origin'],
          'HAB_NONINTERACTIVE' => 'true',
        }

        env['RUST_LOG'] = 'debug' if @log.level == :debug

        # TODO: Would love to use Mixlib::ShellOut here, but it doesn't
        # seem to preserve the STDIN tty, and docker gets angry.
        Dir.chdir(working_dir) do
          unless system(env, 'hab pkg build .')
            exit_with_error('Unable to build the Habitat artifact.')
          end
        end

        hart_files = Dir.glob(File.join(working_dir, 'results', '*.hart'))

        if hart_files.length > 1
          exit_with_error('More than one Habitat artifact was created which ' \
                          'was not expected.')
        elsif hart_files.empty?
          exit_with_error('No Habitat artifact was created.')
        end

        hart_files.first
      end

      def upload_hart(hart_file, habitat_config)
        @log.info("Uploading '#{hart_file}' to the Habitat Builder Depot...")

        config = habitat_config

        env = {
          'HAB_AUTH_TOKEN'     => config['auth_token'],
          'HAB_NONINTERACTIVE' => 'true',
          'HAB_ORIGIN'         => config['origin'],
          'TERM'               => 'vt100',
        }

        env['HAB_DEPOT_URL'] = ENV['HAB_DEPOT_URL'] if ENV['HAB_DEPOT_URL']

        cmd = Mixlib::ShellOut.new("hab pkg upload #{hart_file}", env: env)
        cmd.run_command
        if cmd.error?
          exit_with_error(
            'Unable to upload Habitat artifact to the Depot.',
            cmd.stdout,
            cmd.stderr,
          )
        end

        @log.info('Upload complete!')
      end

      def read_habitat_config
        cli_toml = File.join(ENV['HOME'], '.hab', 'etc', 'cli.toml')
        cli_toml = '/hab/etc/cli.toml' unless File.exist?(cli_toml)
        cli_config = File.exist?(cli_toml) ? Tomlrb.load_file(cli_toml) : {}
        cli_config['origin'] ||= ENV['HAB_ORIGIN']
        cli_config['auth_token'] ||= ENV['HAB_AUTH_TOKEN']
        cli_config
      end

      def exit_with_error(*errors)
        errors.each do |error_msg|
          @log.error(error_msg)
        end

        raise
      end
    end
  end
end

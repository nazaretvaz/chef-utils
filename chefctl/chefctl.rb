#!/opt/chef/embedded/bin/ruby

require 'date'
require 'English'
require 'fileutils'
require 'logger'
require 'open3'
require 'optparse'
require 'socket'
require 'mixlib/config'
require 'mixlib/shellout'
require 'rubygems'

def quit(message, exitcode = 1)
  Chefctl.logger.error(message)
  exit exitcode
end

module Chefctl
  # Default config file path.
  DEFAULT_CONFIG = '/etc/chefctl-config.rb'.freeze

  # Buffer size to use when reading chef output from stdout.
  BUFFER_SIZE = 1024

  @program_name = File.basename($PROGRAM_NAME)
  @logger = nil
  @lib = nil

  def self.program_name=(v)
    @program_name = File.basename(v)
    @logger.progname = @program_name if @logger
  end

  def self.program_name
    @program_name
  end

  def self.logger
    unless @logger
      @logger = Logger.new(STDOUT)
      @logger.sev_threshold = Logger::INFO
      @logger.formatter = proc do |severity, datetime, progname, msg|
        "[#{datetime}] #{severity} #{progname}: #{msg}\n"
      end

      @logger.progname = program_name
    end
    @logger
  end

  def self.lib
    unless @lib
      # In the future, this should auto-determine that platform type
      # and use the correct Chefctl::Lib{platform} class.
      if Gem.win_platform?
        @lib = Chefctl::Lib::Windows.new
      else
        @lib = Chefctl::Lib::Linux.new
      end
      Chefctl.logger.debug("Using chefctl platform module: #{@lib.class}")
    end
    @lib
  end

  module Config
    extend Mixlib::Config

    # Allow the chef run to provide colored output.
    color false

    # Whether or not chefctl should provide verbose output.
    verbose false

    # The chef-client process to use.
    chef_client '/opt/chef/bin/chef-client'

    # Whether or not chef-client should provide debug output.
    debug false

    # Default options to pass to chef-client.
    chef_options ['--no-fork']

    # Whether or not to provide human-readable output.
    human false

    # If set, ignore the splay and stop pending chefctl processes before
    # running. This is intended for interactive runs of chef
    # (i.e. started by a human).
    immediate false

    # The lock file to use for chefctl.
    lock_file '/var/lock/subsys/chefctl'

    # How long to wait for the lock to become available.
    lock_time 1800

    # Directory where per-run chef logs should be placed.
    log_dir '/var/chef/outputs'

    # If set, will not copy chef log to stdout.
    quiet false

    # The default splay to use. Ignored if `immediate` is set to true.
    splay 870

    # How many chef-client retries to attempt before failing.
    # See Chefctl::Plugin.rerun_chef?
    max_retries 1

    # The testing timestamp.
    # See https://github.com/facebook/taste-tester
    testing_timestamp '/etc/chef/test_timestamp'

    # Whether or not to run chef in whyrun mode.
    whyrun false

    # The default location of the chefctl plugin file.
    plugin_path '/etc/chef/chefctl_hooks.rb'

    # The default PATH environment variable to use for chef-client.
    path %w{
      /usr/sbin
      /usr/bin
    }

    # Whether or not to symlink output files for chef.cur.out and chef.last.out
    symlink_output true
  end

  # Chefctl plugins are used to define custom behavior for chefctl.
  # A fixed set of interaction points are defined below and the corresponding
  # functions are called at the appropriate time during a chefctl run.
  module Plugin
    @plugin_module = nil
    @plugin = nil

    ###
    # Default behavior for plugins
    ###

    # Called during command line option parsing.
    # Allows a plugin to define additional command-line arguments.
    # Parameters:
    # - parser: an OptionParser object
    # The return value is ignored.
    def cli_options(parser); end

    # Called between command line parsing, and acquiring the lock.
    # This hook is intended to be used to modify config options via
    # Chefctl::Config, or do other setup items for the hooks.
    # Setup items for the chef run should be placed in pre_run, since
    # pre_start is called before the lock is acquired.
    # The return value is ignored.
    def pre_start; end

    # Gets the hostname of the machine. This sets the HOSTNAME environment
    # variable for the chef-client process.
    # Returns the hostname of the machine as a string.
    def hostname
      Socket.gethostname
    end

    # Validates the authenticity of chef certificates, regenerating
    # them if necessary.
    # The return value is ignored.
    def generate_certs
      client_prod_cert = '/etc/chef/client-prod.pem'
      if File.zero?(client_prod_cert)
        Chefctl.logger.info('zero-byte client pem found, removing')
        File.unlink(client_prod_cert)
      end
    end

    # Called after the lock is acquired, before the chef run is started.
    # Parameters:
    # - output is the path to the log file for the chef run
    # The return value is ignored.
    def pre_run(_output); end

    # Called after the final chef run completes, before the lock is released.
    # Normally this would be after the first (and only) chef run, but
    # re-runs can be triggered by the `rerun_chef?` hook, in which case
    # this hook is called exactly once after the final chef run.
    # Parameters:
    # - output is the path to the log file for the chef run.
    # - chef_exitcode is the exit code of the final chef-client process.
    #   (>0 on failure)
    # The return value is ignored.
    def post_run(_output, _chef_exitcode); end

    # Check whether or not another chef run is required.
    # Parameters:
    # - output is the path to the log file for the chef run.
    # - chef_exitcode is the chef-client exit code. (>0 on failure)
    # Returns a boolean indicating if another chef run should be performed.
    # This hook is called at most `Chefctl::Config.max_retries` times.
    # With the default value of 1 retry, this hook is not called a second time,
    # regardless of the result of the chef re-run.
    def rerun_chef?(_output, _chef_exitcode)
      false
    end

    ###
    # Helpers
    ###

    # Short-hand helper that returns a meaningful logger.
    def logger
      Chefctl.logger
    end

    # Returns an object with the registered plugin included in it.
    def self.get_plugin
      unless @plugin
        # we can't look up class variables in the class block below,
        # so we 'alias' it as a local variable
        m = @plugin_module

        # concrete is the class for our plugin object.
        # It's just an empty class which includes the modules for our plugin.
        concrete = Class.new do
          # Include the base Plugin, which includes the defaults for plugin
          # behaviors.
          include Plugin

          if m
            Chefctl.logger.debug("Including registered plugin #{m}")
            include m
          end
        end
        Chefctl.const_set('ConcretePlugin', concrete)
        @plugin = concrete.new
      end
      @plugin
    end

    # Registers a module as the plugin.
    def self.register(mod)
      if @plugin_module
        Chefctl.logger.warn("Plugin #{@plugin_module} already registered. " +
                            "Using new plugin #{mod} instead.")
      end
      @plugin_module = mod
    end

    # Loads the plugin from a file
    def self.load_file(filename)
      filename = File.expand_path(filename)
      if File.exists? filename
        Chefctl.logger.debug("Loading plugin at #{filename}.")
        begin
          require_relative filename
        rescue LoadError => e
          Chefctl.logger.debug("While loading #{filename} got error: #{e}")
          Chefctl.logger.warn("Failed to load plugin #{filename}. Failing!")
          raise
        end
      else
        Chefctl.logger.info("Plugin file not found at #{filename}. Ignoring.")
      end
    end
  end # class Plugin

  # Platform-independent helper functions
  module Lib
    # waits for currently running chef processes to exit.
    # If there are running chefctl processes but no chef-client processes, the
    # chefctl processes are killed so this process can run.
    # This is primarily for use with interactive tools (-i/--immediate)
    def stop_or_wait_for_chef(logfile = false)
      # check to see whether or not chef is running
      return if chefctl_procs.empty?
      return if logfile && !File.exists?(logfile)

      client_name = File.basename(Chefctl::Config.chef_client)

      # each chefctl instance can show up as 1-3 processes. so best case, we'll
      #
      # only queue 5 runs. worse case we'll queue 15 runs.
      if chefctl_procs.length < 15

        STDOUT.sync = true

        unless chefclient_procs.empty?
          # chef-client is currently running. we don't want to just kill it,
          # instead we want to wait for it to finish

          STDOUT << "Waiting for #{client_name} runs to complete "
          until chefclient_procs.empty?
            STDOUT << '.'
            sleep 5
          end
          STDOUT << "\nChef-client runs completed.\n"
        end

        STDOUT.sync = false

        # no more chef-client processes running. kill any chefctls left over
        procs = chefctl_procs
        unless procs.empty?
          Chefctl.logger.debug('Killing other chefctl processes: ' +
                               procs.join(' '))
          kill_processes(procs)
        end
      else
        quit 'Several chef runs already queued. Not queueing any more.', 0
      end
    end

    # Returns a standard formatted timestamp of the current time.
    def get_timestamp
      DateTime.now.strftime('%Y%m%d.%H%M.%s')
    end

    # Sets the mtime of a file.
    def set_mtime(file, new_time)
      stat = File.stat(file)
      File.utime(stat.atime, new_time, file)
    end

    # Checks that the current user is authorized to run chef.
    # I.e. they are root.
    def check_user
      proc_name = File.basename($PROGRAM_NAME)
      quit "You must be root to run #{proc_name}" unless Process.euid.zero?
    end

    # Loads the config file using the provided cli_options as overrides
    # to the defaults.
    def load_config(config_file, cli_options = {})
      validate_options(cli_options)
      Chefctl.logger.debug("Loading config at: #{config_file}")
      filename = File.expand_path(config_file)
      if File.exists?(filename)
        Chefctl::Config.from_file(filename)
      end
      Chefctl::Config.merge!(cli_options)
    end

    def validate_options(options)
      if options[:splay] && options[:immediate]
        Chefctl.logger.error('Splay and immediate options are mutually ' +
                             'exclusive. You passed both. Try again.')
        exit 1
      end
    end

    # Linux platform-dependent helpers
    class Linux
      include Chefctl::Lib

      # Runs the provided command as a shell command. Returns the stdout of
      # the command. Raises an exception if the command fails.
      def shell_output(command)
        ps = Mixlib::ShellOut.new(command)
        yield(ps) if block_given?
        ps.run_command.error!
        ps.stdout
      end

      # returns an array of pids of running chefctl processes
      def chefctl_procs
        out = shell_output('ps -e -o pid,command')

        # chef_procs is a hash of {pid => cmd}
        chef_procs = Hash[out.lines.map do |l|
          fields = l.split
          [fields[0].to_i, fields[1..fields.length].join(' ')]
        end]

        # only want processes with `chefctl` in their argument list
        chef_procs.select! { |_pid, cmd| /chefctl/ =~ cmd }

        # if someone is editing/viewing chefctl on the box,
        # don't kill their editor.
        [
          /vi/,
          /less/,
          /ssh/,
          /more/,
          /emacs/,
        ].each do |editor|
          chef_procs.reject! { |_pid, cmd| editor =~ cmd }
        end

        # Don't kill process directly above us in the process tree.
        parents = parent_group(Process.pid)
        chef_procs.reject! do |pid, _cmd|
          parents.include?(pid)
        end

        # return only the pids
        chef_procs.keys
      end

      # returns an array of pids of running chef-client processes
      def chefclient_procs
        # chef_client may be a full path
        client_name = File.basename(Chefctl::Config.chef_client)
        out = shell_output("pgrep #{client_name}") do |pgrep|
          pgrep.valid_exit_codes = [0, 1]
        end
        out.lines
      end

      # Sends sigterm to the list of processes identifiers provided.
      def kill_processes(procs)
        Process.kill('SIGTERM', *procs)
      end

      # Reads from the provided file, non-blocking
      def read_nonblock(f)
        f.read_nonblock(Chefctl::BUFFER_SIZE)
      end

      private

      # returns the parent of a given process
      def parent_process(pid)
        out = shell_output("ps -o ppid -p #{pid}")
        ppid = -1
        out.each_line do |l|
          next if /PPID/ =~ l
          ppid = l.strip.to_i
        end
        fail "Couldn't determine ppid of #{pid}" if ppid == -1
        ppid
      end

      # returns an array of pids that are in the parent tree of the provided
      # process (including itself)
      # e.g. if A forks B, B forks C, and B forks D:
      # parent_group(C) => [A, B, C]
      # parent_group(B) => [A, B]
      # parent_group(D) => [A, B, D]
      def parent_group(current)
        parents = []
        while current.nonzero?
          parents << current
          current = parent_process(current)
        end
        parents
      end
    end # class Linux

    class Windows
      include Chefctl::Lib

      # returns an array of pids of running chefctl processes
      def chefctl_procs
        require 'wmi-lite'
        this_pid = Process.pid
        wmi = WmiLite::Wmi.new
        chefctl_procs = %{
          SELECT
            *
          FROM
            Win32_Process
          WHERE
            CommandLine LIKE "%chefctl%"
          AND
            Name LIKE "%ruby%"
          AND
            ProcessId <> #{this_pid}
        }

        wmi.query(chefctl_procs).map { |p| p['processid'] }
      end

      # returns an array of pids of running chef-client processes
      def chefclient_procs
        require 'wmi-lite'
        this_pid = Process.pid
        wmi = WmiLite::Wmi.new
        chefctl_procs = %{
          SELECT
            *
          FROM
            Win32_Process
          WHERE
            CommandLine LIKE "%chef-client%"
          AND
            Name LIKE "%ruby%"
          AND
            ProcessId <> #{this_pid}
        }

        wmi.query(chefctl_procs).map { |p| p['processid'] }
      end

      # Sends sigterm to the list of processes identifiers provided.
      def kill_processes(procs)
        procs.each do |pid|
          Mixlib::ShellOut.new("TASKKILL /F /PID #{pid}").run_command
        end
        sleep(2) # Give time for lock to release
      end

      # Reads from the provided file, non-blocking
      def read_nonblock(logf)
        logf.sysread(Chefctl::BUFFER_SIZE)
      end
    end # class Windows
  end # class Lib

  class Main
    attr_accessor :plugin
    def initialize
      @plugin = Chefctl::Plugin.get_plugin

      logdate = Chefctl.lib.get_timestamp
      logdir = Chefctl::Config.log_dir
      @chef_name = File.basename(Chefctl::Config.chef_client)
      @lock = {
        :file => Chefctl::Config.lock_file,
        :time => Chefctl::Config.lock_time,
        :fd => nil, # opened lock file
        :held => false,
      }
      @paths = {
        # Directories
        :logdir => logdir,

        # Output files
        :chef_cur => File.join(logdir, 'chef.cur.out'),
        :chef_last => File.join(logdir, 'chef.last.out'),
        :out => File.join(logdir, "chef.#{logdate}.out"),
        :first => File.join(logdir, 'chef.first.out'),
      }
    end

    # waits the given timeout for the lock identified by @lock[:fd] to become
    # available. timeout values <0 mean that it should try the lock exactly
    # once and not wait.
    def wait_for_lock(timeout = -1)
      # open the lockfile
      # we leave it open if we can acquire the lock,
      # otherwise we close it before we exit this function
      if File.exists?(@lock[:file])
        @lock[:fd] = File.open(@lock[:file], 'r+')
      else
        @lock[:fd] = File.new(@lock[:file], 'w')
      end

      endtime = Time.now + timeout
      loop do
        acquired = @lock[:fd].flock(File::LOCK_EX | File::LOCK_NB)
        return true if acquired

        if Time.now >= endtime
          @lock[:fd].close
          return false
        else
          sleep 2
        end
      end
    end

    # extend testing duration to 1 hour from now, if it's not longer than that
    # already
    def keep_testing
      stamp_file = Chefctl::Config.testing_timestamp
      return unless File.exists?(stamp_file)
      now = Time.now
      new_time = now + 3600
      if File.mtime(stamp_file) - now < 3600
        Chefctl.logger.info('taste-tester mode ends in < 1 hour, ' +
                            'extending back to 1 hour')
        Chefctl.lib.set_mtime(stamp_file, new_time)
      end
    end

    # Acquire the lock
    def acquire_lock
      if Chefctl::Config.immediate
        Chefctl.lib.stop_or_wait_for_chef(@paths[:chef_cur])
      end

      Chefctl.logger.debug("Trying lock #{@lock[:file]}")
      acquired = wait_for_lock(-1)
      unless acquired
        held = nil
        File.open(@lock[:file], 'r') do |f|
          held = f.read.strip
        end
        Chefctl.logger.info("#{@lock[:file]} is locked by #{held}, " +
                            "waiting up to #{@lock[:time]} seconds.")
        unless wait_for_lock(@lock[:time])
          quit "Unable to lock #{@lock[:file]}"
        end
      end
      Chefctl.logger.debug("Lock acquired: #{@lock[:file]}")

      # mark us as owning the lock file
      @lock[:fd].write(Process.pid.to_s)

      # flush the pid to disk
      @lock[:fd].flush

      @lock[:held] = true
    end

    # Release the lock, if it's being held.
    def release_lock
      if @lock[:fd]
        if @lock[:held]
          @lock[:fd].flock(File::LOCK_UN)
          Chefctl.logger.debug("Releasing lock: #{@lock[:file]}")
        end

        # Some platforms panic if you try to unlink a file with open file
        # handles. /me glares silently in the direction of Redmond...
        @lock[:fd].close

        File.unlink(@lock[:file]) if File.exists?(@lock[:file]) && @lock[:held]
        @lock[:fd] = nil
      end
    end

    # acquire the lock, and `yield` within it.
    def lock
      acquire_lock
      yield
    rescue StandardError => e
      Chefctl.logger.error("Failed inside lock: #{e.inspect}:" +
                           "\n    #{e.backtrace.join("\n    ")}")
      raise
    ensure
      release_lock
    end

    # Perform a chef run
    def chef_run
      Chefctl.lib.check_user

      retval = 0
      lock do
        keep_testing
        plugin.generate_certs

        if File.file?(@paths[:logdir])
          quit "Log directory #{@paths[:logdir]} is a file."
        end
        FileUtils.mkdir_p(@paths[:logdir], :mode => 0o775) unless
            File.exists?(@paths[:logdir])
        FileUtils.touch(@paths[:out])

        symlink_output(:chef_cur)

        do_splay unless Chefctl::Config.immediate

        plugin.pre_run(@paths[:out])

        retval = do_chef_runs

        plugin.post_run(@paths[:out], retval)

        symlink_output(:chef_last)

        save_firstrun
      end

      if retval > 0
        if Chefctl::Config.immediate || !Chefctl::Config.quiet
          Chefctl.logger.info("#{@chef_name} failed with exit code #{retval}," +
                       ' check log output!')
        end
      end
      return retval
    end

    # Symlink the current chef output file to the
    # provided link (key into @paths)
    def symlink_output(link)
      return unless Chefctl::Config.symlink_output
      FileUtils.ln_s(@paths[:out], @paths[link], :force => true)
    end

    # Splay for the configured amount.
    # Waits for a random number in [1, Chefctl::Config.splay] seconds then
    # returns.
    def do_splay
      return unless Chefctl::Config.splay > 0

      t = rand(Chefctl::Config.splay)
      Chefctl.logger.info("splay: sleeping for #{t} seconds.")

      # Ruby doesn't respond to SIGTERM inside a sleep call.
      # So we sleep in one second intervals. This way if something sends us
      # a SIGTERM we can respond within a second.
      endtime = Time.now + t
      loop do
        if Time.now >= endtime
          return
        else
          sleep 1
        end
      end
    end

    # Runs chef until either it's been run Chefctl::Config.max_retries+1 times,
    # or the rerun_chef? returns False.
    def do_chef_runs
      retval = 0
      num_tries = 0
      loop do
        retval = run
        num_tries += 1

        # break if we've already run chef the max number of times
        if num_tries > Chefctl::Config.max_retries
          Chefctl.logger.debug('Hit max retries. Not running chef again.')
          break
        end

        # break unless we need to rerun chef for some reason
        unless plugin.rerun_chef?(@paths[:out], retval)
          Chefctl.logger.debug('rerun_chef? was false. Not running chef again.')
          break
        end
        Chefctl.logger.warn('Chef failed. Attempting to re-run chef.')
      end
      return retval
    end

    # Returns the chef command and arguments, as a string.
    def get_chef_cmd
      # Chef arguments from config.
      chef_args = []

      # Special command-line arguments
      chef_args << '-l debug' if Chefctl::Config.debug
      if Chefctl::Config.human || Chefctl::Config.whyrun
        chef_args << '-l fatal -F doc'
      end
      chef_args << '--why-run' if Chefctl::Config.whyrun
      chef_args << '--no-color' unless Chefctl::Config.color

      chef_args += Chefctl::Config.chef_options

      # Join them all together
      cmd = "#{Chefctl::Config.chef_client} " + chef_args.join(' ')

      # we want to append the output instead of overwriting the file in case
      # this is a re-run of chef.
      cmd << " 2>&1 >> #{@paths[:out]}"

      Chefctl.logger.debug("Running: #{cmd}")

      cmd
    end

    # Returns the environment for the chef process, as a hash
    def get_chef_env
      hostname = plugin.hostname

      {
        'HOSTNAME' => hostname,
        'PATH' => Chefctl::Config.path.join(':'),
      }
    end

    # copy data from the pipe to stdout and the log file.
    # return false if we reach the end of the file.
    def copy_output(logf)
      begin
        data = Chefctl.lib.read_nonblock(logf)
        STDOUT << data
      rescue EOFError
        return false
      end
      return true
    end

    # Returns a thread that is used to copy output from the log file
    # to chefctl's (this processes's) stdout.
    # If we're running in quiet mode we don't need this at all, so returns nil
    # The thread runs indefinitely until it is sent a RuntimeError via the
    # `raise` method. When it receives a RuntimeError, it will flush any
    # remaining log data, and close the log file.
    def output_copier_thread
      return nil if Chefctl::Config.quiet

      # Thread to copy the output from the file to stdout
      output_t = Thread.new do
        logf = File.open(@paths[:out], 'r')

        # seek over any data already in the file
        logf.seek(0, IO::SEEK_END)

        begin
          # Loop until we're sent a RuntimeError from the main thread.
          loop do
            # If we hit the EOF here, it means we're caught up, but chef
            # might write more stuff later. Sleep for a bit and try again.
            sleep(0.1) unless copy_output(logf)
          end
        rescue RuntimeError => e
          # flush anything left in the file to STDOUT
          # When we hit EOF, that's the actual end, so we're done.
          while copy_output(logf)
          end

          Chefctl.logger.debug("Stopped output copier: #{e}")
        ensure
          logf.close
        end
      end

      # we want to give the thread some time to start running, so that the
      # first bit of output of the chef run isn't lost
      sleep(0.1)

      output_t
    end

    # Perform a chef run.
    def run
      output_t = output_copier_thread

      # We don't want a timeout at all here, but ShellOut doesn't have
      # a way to disable the timeout, so we set it to 1 day, which is WAAAY
      # longer than any reasonable chef run should take.
      # Timeouts are enforced elsewhere at way lower than 1 day.
      chef_client = Mixlib::ShellOut.new(get_chef_cmd, :timeout => 86400)
      chef_client.environment = get_chef_env
      chef_client.run_command

      # output_t is nil if we're running with -q/--quiet
      if output_t
        # The output thread is tailing the output of the log file.
        # We need to interrupt it to stop the tail. Otherwise calling join
        # would just wait indefinitely.
        output_t.raise('this is normal')
        output_t.join(3)
      end

      return chef_client.exitstatus
    end

    # Saves the output from the very first chef run indefinitely so we have
    # information about how the machine was originally setup.
    def save_firstrun
      unless File.exists?(@paths[:first])
        # It's a first-run if there's only 1 chef log.
        # The glob here depends on our log date formatting above in
        # Chefctl::Lib.get_timestamp
        if Dir.glob(File.join(@paths[:logdir], 'chef.2*')).length == 1
          # Copy, don't symlink so it's not deleted later as more chef runs
          # happen.
          FileUtils.cp(@paths[:out], @paths[:first])
        end
      end
    end
  end # class Main
end # module Chefctl

class TwoPassParser < OptionParser
  attr_accessor :first_pass

  def initialize(*args)
    @first_pass = true
    super(*args)
  end

  def parse_both_passes(argv = nil)
    first_pass = argv || ARGV
    second_pass = Array.new(first_pass)
    begin
      parse(first_pass)
    rescue OptionParser::InvalidOption => e
      # Invalid arguments during the first pass are expected since
      # the hook hasn't had a chance to define options yet.
      Chefctl.logger.debug("Got an invalid argument #{e.args} during the " +
                           'first pass. Ignoring.')
      # OptionParser will raise an InvalidOption exception whenever it finds
      # an option it doesn't know. When we get this, we delete the offending
      # options, and retry parsing options.
      e.args.each do |a|
        first_pass.delete(a)
      end
      retry
    end
    @first_pass = false
    yield
    parse!(second_pass)
    second_pass
  end
end # class TwoPassParser

if __FILE__ == $PROGRAM_NAME
  Chefctl.lib

  config_file = Chefctl::DEFAULT_CONFIG
  options = {}

  parse = TwoPassParser.new do |parser|
    parser.banner = "Usage: #{$PROGRAM_NAME} [options]"

    parser.separator ''
    parser.separator 'Options:'

    # First-pass-only options:

    parser.on(
      '-C', '--config FILE',
      "Config file [default: #{Chefctl::DEFAULT_CONFIG}]"
    ) do |file|
      config_file = file if parser.first_pass
    end

    parser.on(
      '-p', '--plugin-path FILE',
      'Path to chefctl plugin file'
    ) do |v|
      # Only load the plugin path in the first pass, since we parse it
      # before doing the second pass.
      options[:plugin_path] = v if parser.first_pass
    end

    # Second-pass-only options:
    parser.on('-h', '--help') do
      # Only provide help in the second pass after we've let the hook define
      # additional command-line arguments.
      unless parser.first_pass
        puts parser
        exit 0
      end
    end

    # Pass-agnostic options:

    parser.on('-v', '--verbose', 'Verbose output from chefctl') do
      options[:verbose] = true
    end

    parser.on('-c', '--color', 'Enable colors') do
      options[:color] = true
    end

    parser.on(
      '-d', '--debug',
      'Enable chef debugging. This is a shortcut to passing " -- -l debug"' +
      ' directly'
    ) do
      Chefctl.logger.sev_threshold = Logger::DEBUG
      options[:debug] = true
    end

    parser.on(
      '-H', '--human', 'Use "report handlers" aka. human readable output'
    ) do
      options[:human] = true
    end

    parser.on('-n', '--why-run', 'Enable why-run mode (like dry-run)') do
      options[:whyrun] = true
    end

    parser.on(
      '-i', '--immediate',
      'Execute immediately. No splay. Safely stop other chefctl processes' +
      ' that are queued. Mutually exclusive with -s option.'
    ) do
      options[:immediate] = true
    end

    parser.on(
      '-l', '--lock-timeout TIME',
      "Lock timeout. [default: #{Chefctl::Config.lock_time}]"
    ) do |v|
      options[:lock_time] = v.to_i
    end

    parser.on(
      '-L', '--lock-file FILE',
      "Lock file [default: #{Chefctl::Config.lock_file}]"
    ) do |v|
      options[:lock_time] = v
    end

    parser.on('-q', '--quiet', 'Do not print output to terminal') do
      options[:quiet] = true
    end

    parser.on(
      '-s', '--splay SECONDS',
      'Set the maximum number of seconds for random splay. Mutually exclusive' +
      " with the -i option. [default: #{Chefctl::Config.splay}]"
    ) do |v|
      options[:splay] = v.to_i
    end

    parser.on(
      '--program PROGRAM',
      "name of the chefctl process. defaults to '#{$PROGRAM_NAME}'",
    ) do |v|
      Chefctl.program_name = v
    end
  end

  args = parse.parse_both_passes do
    Chefctl.lib.load_config(config_file, options)
    Chefctl.logger.sev_threshold = Logger::DEBUG if Chefctl::Config.verbose
    Chefctl::Plugin.load_file(Chefctl::Config.plugin_path)
    Chefctl::Plugin.get_plugin.cli_options(parse)
  end

  Chefctl::Plugin.get_plugin.pre_start

  args.delete('--')
  Chefctl::Config.chef_options += args

  exit Chefctl::Main.new.chef_run
end
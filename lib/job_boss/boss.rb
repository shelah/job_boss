module JobBoss
  class Boss
    class << self
      # Used to set Boss configuration
      # Usage:
      #   Boss.config.sleep_interval = 2
      def config
        require 'job_boss/config'
        @@config ||= Config.new
      end

      # Used to queue jobs
      # Usage:
      #   Boss.queue.math.is_prime?(42)
      def queue
        require 'job_boss/queuer'
        @@queuer ||= Queuer.new
      end
    end

    def initialize(options = {})
      @@config.working_dir          ||= options[:working_dir]
      @@config.sleep_interval       ||= options[:sleep_interval]
      @@config.employee_limit       ||= options[:employee_limit]
      @@config.database_yaml_path   ||= options[:database_yaml_path]
      @@config.jobs_path            ||= options[:jobs_path]

      @running_jobs = []
    end

    # Start the boss
    def start
      require 'active_record'
      require 'yaml'

      connect

      require_job_classes

      require 'job_boss/job'

      migrate

      Signal.trap("HUP") do
        self.stop
      end

      at_exit do
        stop if Process.pid == BOSS_PID
      end

      puts "Job Boss started"

      while true
        unless (children_count = available_employees) > 0 && Job.pending.count > 0
          sleep(@@config.sleep_interval)
          next
        end

        Job.pending_paths.each do |path|
          job = Job.pending.find_by_path(path)
          next if job.nil?

          job.dispatch
          @running_jobs << job

          children_count -= 1
          break unless children_count > 0
        end

      end
    end

    def stop
      puts "Stopping #{@running_jobs.size} running employees..."

      shutdown_running_jobs

      puts "Job Boss stopped"
    end
  end

private
  # Cleans up @running_jobs variable, getting rid of jobs which have
  # completed, which have been cancelled, or which went MIA
  def cleanup_running_jobs
    Job.uncached do
      @running_jobs = Job.running.where('id in (?)', @running_jobs)

      cancelled_jobs = @running_jobs.select(&:cancelled?)
      cancelled_jobs.each {|job| kill_job(job) }
      @running_jobs -= cancelled_jobs

      # Clean out any jobs whos processes have stopped running for some reason
      @running_jobs = @running_jobs.select do |job|
        begin
          Process.kill(0, job.employee_pid.to_i)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end

  # Total number of employees which can be run
  def available_employees
    cleanup_running_jobs

    @@config.employee_limit - @running_jobs.size
  end

  def connect
    @@config.database_yaml_path = File.join(@@config.working_dir, @@config.database_yaml_path) unless @@config.database_yaml_path[0] == ?/

    raise "Database YAML file missing (#{@@config.database_yaml_path})" unless File.exist?(@@config.database_yaml_path)

    config = YAML.load(File.read(@@config.database_yaml_path))

    ActiveRecord::Base.establish_connection(config[@@config.environment])
  end

  def require_job_classes
    @@config.jobs_path = File.join(@@config.working_dir, @@config.jobs_path) unless @@config.jobs_path[0] == ?/

    raise "Jobs path missing (#{@@config.jobs_path})" unless File.exist?(@@config.jobs_path)

    Dir.glob(File.join(@@config.jobs_path, '*.rb')).each {|job_class| require job_class }
  end

  def migrate
    unless Job.table_exists?
      require 'migrate'
      CreateJobs.up
    end
  end

  def kill_job(job)
    begin
      Process.kill("HUP", job.employee_pid.to_i)
    rescue Errno::ESRCH
      nil
    end
  end

  def shutdown_running_jobs
    cleanup_running_jobs

    @running_jobs.each do |job|
      kill_job(job)
      job.mark_for_redo
    end
  end

end
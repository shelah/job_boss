# job_boss

## Credits

The idea for this gem came from trying to use working/starling and not having much success with stability.  I created job_boss after some discussions with my colleagues (Neil Cook and Justin Hahn).  Thanks also to my employer, [RBM Technologies](http://www.rbmtechnologies.com) for letting me take some of this work open-source.

## Purpose

job_boss allows you to have a daemon much in the same way as workling which allows you to process a series of jobs asynchronously.   job_boss, however, uses ActiveRecord to store queued job requests in a database thus simplifying dependencies.  This allows for us to process chunks of work in parallel, across multiple servers, without needing much setup

## Overview

 * job_boss uses ActiveRecord to store/poll it's queue.  It's not dependent on Rails, but if it sees that it's being run in a Rails environment, it will automatically load the environment.rb file
 * Loading up the environment.rb file isn't a big deal because job_boss's model has a main "boss" process which is a deamon.  The boss forks employees as needed to execute jobs.
 * Employees only exist for the span of one job, so there's less concern about a build up in memory from leaks (not that we shouldn't be addressing leaks...)
 * The boss is independent and always polling, so it can look for jobs which have been marked an cancelled and kill the employee during processing

## Usage

Add the gem to your Gemfile

    gem 'job_boss'

or install it

    gem install job_boss

Create a directory to store classes which define code which can be executed by the job boss (the default directory is 'app/jobs') and create class files such as this:

    # app/jobs/math_jobs.rb
    class MathJobs
        def is_prime?(i)
            ('1' * i) !~ /^1?$|^(11+?)\1+$/
        end
    end

If you're using Rails, much of the logic that you'll want to queue may already be in models or other application classes.  You can queue class methods rather that needing to wrap them in a Job class:

    # app/models/article.rb
    class Article < ActiveRecord::Base
        class << self
            def refresh_cache(article_ids)
                # code to refresh article cache
            end
        end
    end

Start up your boss:

    job_boss start -- <options>

You can get command line options with the command:

    job_boss run -- -h

But since you don't want to do that right now, it looks something like this:

    Usage: job_boss [start|stop|restart|run|zap] [-- <options>]
        -r, --application-root PATH      Path for the application root upon which other paths depend (defaults to .)  Environment variable: JB_APPLICATION_ROOT
        -d, --database-yaml PATH         Path for database YAML (defaults to <application-root>/config/database.yml) Environment variable: JB_DATABASE_YAML_PATH
        -l, --log-path PATH              Path for log file (defaults to <application-root>/log/job_boss.log) Environment variable: JB_LOG_PATH
        -j, --jobs-path PATH             Path to folder with job classes (defaults to <application-root>/app/jobs) Environment variable: JB_JOBS_PATH
        -e, --environment ENV            Environment to use in database YAML file (defaults to 'development') Environment variable: JB_ENVIRONMENT
        -s, --sleep-interval INTERVAL    Number of seconds for the boss to sleep between checks of the queue (default 0.5) Environment variable: JB_SLEEP_INTERVAL
        -c, --employee-limit LIMIT       Maximum number of employees (default 4) Environment variable: JB_EMPLOYEE_LIMIT

From your Rails code or in a console:

    require 'job_boss'
    batch = Batch.new
    jobs = (0..1000).collect do |i|
        batch.queue.math.is_prime?(i)
    end

Or:

    jobs = []
    batch = Batch.new
    Article.select('id').find_in_batches(:batch_size => 10) do |articles|
        jobs << batch.queue.article.refresh_cache(articles.collect(&:id))
    end

job_boss also makes it easy to wait for the jobs to be done and to collect the results into a hash:

    batch.wait_for_jobs # Will sleep until the jobs are all complete

    batch.result_hash # => {[0]=>false, [1]=>false, [2]=>true, [3]=>true, [4]=>false, ... }

You can even define a block to provide updates on progress (the value which is passed into the block is a float between 0.0 and 1.0):

    batch.wait_for_jobs do |progress|
        puts "We're now at #{progress * 100}%"
    end

Prioritization of jobs is also supported.  If a particular batch is more important than others, you can specify a higher priority

    batch = Batch.new(:priority => 3)

In practical terms, the priority represents the number of jobs which are pulled from the queue to be processed each cycle, so by wary of increasing your priority beyond your maximum number of employees.  No job queue will suffer from resource starvation, but you can greatly decrease the performance of other queues by over-prioritizing one.

Also note that job_boss uses a prioritized round-robin approach to scheduling jobs, the priority for jobs is increased throughout the run of the job queue, providing an approximation of a first-come first-serve approach to reduce latency.

For performance, it is recommended that you keep your jobs table clean scheduling execution of the `delete_jobs_before` command on the Job model, which will clean all jobs completed before the specified time:

    Job.delete_jobs_before(2.days.ago)

Features:

 * Call the `cancel` method on a job to have the job boss cancel it
 * Call the `mark_for_redo` method on a job to have it processed again.  This is automatically run for all currently running jobs in the event that the boss has been told to stop
 * If a job throws an exception, it will be caught and recorded.  Call the `error` method on a job to find out what the error was
 * Find out how long the job took by calling the `time_taken` method on a job
 * The job boss dispatches "employees" to work on jobs.  Viewing the processes, the process name is changed to reflect which jobs employees are working on for easy tracing (e.g. `[job_boss employee] job #4 math#is_prime?(4)`)
 
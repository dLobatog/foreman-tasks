module ForemanTasksCore
  module Runner
    class Dispatcher
      def self.instance
        return @instance if @instance
        @instance = new(ForemanTasksCore.dynflow_world.clock,
                        ForemanTasksCore.dynflow_world.logger)
      end

      class RunnerActor < ::Dynflow::Actor
        def initialize(dispatcher, suspended_action, runner, clock, logger, options = {})
          @dispatcher = dispatcher
          @clock = clock
          @logger = logger
          @suspended_action = suspended_action
          @runner = runner
          @finishing = false
          @refresh_interval = options[:refresh_interval] || 1
        end

        def on_envelope(*args)
          super
        rescue => e
          handle_exception(e)
        end

        def start_runner
          @logger.debug("start runner #{@runner.id}")
          @runner.start
          refresh_runner
        ensure
          plan_next_refresh
        end

        def refresh_runner
          @logger.debug("refresh runner #{@runner.id}")
          if (update = @runner.run_refresh)
            @suspended_action << update
            finish if update.exit_status
          end
        ensure
          @refresh_planned = false
          plan_next_refresh
        end

        def kill
          @logger.debug("kill runner #{@runner.id}")
          @runner.kill
        rescue => e
          handle_exception(e, false)
        end

        def finish
          @logger.debug("finish runner #{@runner.id}")
          @finishing = true
          @dispatcher.finish(@runner.id)
        end

        def start_termination(*args)
          @logger.debug("terminate #{@runner.id}")
          super
          @runner.close
          finish_termination
        end

        private

        def plan_next_refresh
          if !@finishing && !@refresh_planned
            @logger.debug("planning to refresh #{@runner.id}")
            @clock.ping(reference, Time.now.getlocal + @refresh_interval, :refresh_runner)
            @refresh_planned = true
          end
        end

        def handle_exception(exception, fatal = true)
          @dispatcher.handle_command_exception(@runner.id, exception, fatal)
        end
      end

      def initialize(clock, logger)
        @mutex = Mutex.new
        @clock = clock
        @logger = logger
        @runner_actors = {}
        @runner_suspended_actions = {}
      end

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def start(suspended_action, runner)
        synchronize do
          begin
            raise "Actor with runner id #{runner.id} already exists" if @runner_actors[runner.id]
            runner.logger = @logger
            runner_actor = RunnerActor.spawn("runner-actor-#{runner.id}", self, suspended_action, runner, @clock, @logger)
            @runner_actors[runner.id] = runner_actor
            @runner_suspended_actions[runner.id] = suspended_action
            runner_actor.tell(:start_runner)
            return runner.id
          rescue => exception
            _handle_command_exception(runner.id, exception)
            return nil
          end
        end
      end

      def kill(runner_id)
        synchronize do
          begin
            runner_actor = @runner_actors[runner_id]
            runner_actor.tell(:kill) if runner_actor
          rescue => exception
            _handle_command_exception(runner_id, exception, false)
          end
        end
      end

      def finish(runner_id)
        synchronize do
          begin
            _finish(runner_id)
          rescue => exception
            _handle_command_exception(runner_id, exception, false)
          end
        end
      end

      def handle_command_exception(*args)
        synchronize { _handle_command_exception(*args) }
      end

      private

      def _finish(runner_id)
        runner_actor = @runner_actors.delete(runner_id)
        return unless runner_actor
        @logger.debug("closing session for command [#{runner_id}]," \
                      "#{@runner_actors.size} actors left ")
        runner_actor.tell([:start_termination, Concurrent.future])
      ensure
        @runner_suspended_actions.delete(runner_id)
      end

      def _handle_command_exception(runner_id, exception, fatal = true)
        @logger.error("error while dispatching request to runner #{runner_id}:"\
                      "#{exception.class} #{exception.message}:\n #{exception.backtrace.join("\n")}")
        suspended_action = @runner_suspended_actions[runner_id]
        if suspended_action
          suspended_action << Runner::Update.encode_exception('Runner error', exception, fatal)
        end
        _finish(runner_id) if fatal
      end
    end
  end
end

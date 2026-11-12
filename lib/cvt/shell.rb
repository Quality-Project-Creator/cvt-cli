# frozen_string_literal: true

require "open3"

require_relative "errors"

module Cvt
  # Runs external commands with an argv array only (never a shell string),
  # capturing stdout/stderr and enforcing the `--timeout` contract: TERM the
  # child process group, wait five seconds, then KILL. Engines are expected to
  # call this helper instead of Open3 directly so timeout and interrupt
  # handling stay consistent across the CLI.
  module Shell
    TERM_GRACE_SECONDS = 5
    DEBUG_STDERR_LIMIT = 4096
    CHUNK_SIZE = 64 * 1024

    Result = Struct.new(:stdout, :stderr, :status, :timed_out, keyword_init: true) do
      def timed_out?
        !!timed_out
      end

      def success?
        status && status.success?
      end
    end

    module_function

    # With a block, stdout is streamed to it in chunks instead of being
    # buffered, so a caller can stop the engine early (for example when a
    # size limit is reached) without holding the whole output in memory.
    def run(argv, timeout: 0, env: {}, chdir: nil, &block)
      command = Array(argv).map(&:to_s)
      if command.empty?
        return Result.new(stdout: "", stderr: "", status: nil, timed_out: false)
      end

      options = {}
      options[:chdir] = chdir if chdir
      options[:pgroup] = true unless Gem.win_platform?

      stdout = +""
      stderr = +""
      timed_out = false
      status = nil
      stream_error = nil

      Open3.popen3(env, *command, **options) do |stdin, out, err, wait_thr|
        stdin.close
        pid = wait_thr.pid
        out_thread = Thread.new do
          if block
            begin
              loop { block.call(out.readpartial(CHUNK_SIZE)) }
            rescue EOFError
              # The engine closed stdout; the stream is complete.
            rescue StandardError => e
              # The consumer stopped reading: stop the engine so it cannot
              # block on a full pipe, and report the failure to the caller.
              stream_error = e
              kill_process(pid, "KILL")
            end
            +""
          else
            out.read
          end
        end
        err_thread = Thread.new { err.read }
        begin
          if timeout.to_f.positive?
            unless wait_thr.join(timeout.to_f)
              timed_out = true
              terminate(wait_thr, pid)
            end
          else
            wait_thr.join
          end
        ensure
          kill_process(pid, "KILL") if wait_thr.alive?
          out_thread.join
          err_thread.join
        end

        stdout = out_thread.value.to_s
        stderr = err_thread.value.to_s
        status = wait_thr.value
      end

      raise stream_error if stream_error

      Result.new(stdout: stdout, stderr: stderr, status: status, timed_out: timed_out)
    rescue Errno::ENOENT => e
      Result.new(stdout: "", stderr: e.message, status: nil, timed_out: false)
    end

    # Convenience wrapper for engines that want a Cvt::Error on failure.
    def run!(argv, timeout: 0, env: {}, chdir: nil, &block)
      result = run(argv, timeout: timeout, env: env, chdir: chdir, &block)
      if result.timed_out?
        raise Cvt::Errors.build(
          "timeout",
          "External engine timed out after #{timeout} seconds",
          hint: "Increase --timeout or use a faster engine.",
          details: result.stderr.empty? ? nil : { "stderr" => truncate(result.stderr) }
        )
      end
      unless result.success?
        raise Cvt::Errors.build(
          "conversion_failed",
          "External engine failed: #{File.basename(argv.to_a.first.to_s)} exited with " \
            "#{result.status&.exitstatus || "no status"}",
          hint: "Run with --debug for engine stderr, or check that the input file is valid.",
          details: result.stderr.empty? ? nil : { "stderr" => truncate(result.stderr) }
        )
      end

      result
    end

    def truncate(text, limit: DEBUG_STDERR_LIMIT)
      value = text.to_s
      return value if value.bytesize <= limit

      value.byteslice(0, limit).to_s.force_encoding(Encoding::UTF_8).scrub
    end

    def terminate(wait_thr, pid)
      # Windows has no process groups and no deliverable TERM; terminate the
      # child directly instead of waiting for a signal it cannot receive.
      if Gem.win_platform?
        kill_process(pid, "KILL")
        wait_thr.join(TERM_GRACE_SECONDS)
        return
      end

      kill_process(pid, "TERM")
      return if wait_thr.join(TERM_GRACE_SECONDS)

      kill_process(pid, "KILL")
      wait_thr.join(1)
    end

    def kill_process(pid, signal)
      signal = "KILL" if Gem.win_platform?
      target = Gem.win_platform? ? pid : -pid
      Process.kill(signal, target)
    rescue Errno::ESRCH, Errno::EPERM, Errno::EINVAL
      begin
        Process.kill(signal, pid)
      rescue StandardError
        nil
      end
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "async"
require_relative "../lib/campfire/log"

# Runs in a child process so fd 2 can be captured and the log Ractor's
# constant doesn't leak into other tests.
class LogTest < Minitest::Test
  SCRIPT = <<~'RUBY'
    require "async"
    require_relative "lib/campfire/log"
    Campfire::Log.start
    rs = 3.times.map do |i|
      Ractor.new(i, name: "w#{i}") do |i|
        Sync do |task|
          Campfire::Log.attach(task)
          100.times { |n| Campfire::Log.info("r#{i} line #{n}") }
          begin
            raise ArgumentError, "boom"
          rescue => e
            Campfire::Log.error("failed", e)
          end
          sleep 0.3
          task.stop
        end
      end
    end
    rs.each(&:join)
    sleep 0.2
  RUBY

  def test_lines_from_all_ractors_arrive_once_and_in_order
    out = IO.popen([RbConfig.ruby, "-W0", "-e", SCRIPT, chdir: File.expand_path("..", __dir__), err: [:child, :out]], &:read)
    3.times do |i|
      lines = out.lines.grep(/\[w#{i}\] r#{i} line/)
      assert_equal 100, lines.size, out[0, 500]
      assert_equal (0..99).to_a, lines.map { _1[/line (\d+)/, 1].to_i }
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \[w#{i}\]/, lines.first)
      assert_match(/\[w#{i}\] failed: ArgumentError: boom\n.*log_test|-e:/, out)
    end
  end

  def test_falls_back_to_stderr_before_start
    _, err = capture_subprocess_io { Campfire::Log.info("early") }
    assert_equal "early\n", err
  end
end

require "bundler/setup"
require "falcon"
require "async/websocket/adapters/http"
require "extralite"; require "strscan"
require_relative "../lib/ractor_compat"
RactorCompat.share_constants!
r = Ractor.new do
  db = Extralite::Database.new(":memory:")
  db.execute("create virtual table f using fts5(body, tokenize=porter)")
  db.execute("insert into f values ('hello coffee drinking')")
  q = db.prepare_argv("select rowid, body from f where f match ?")
  res = [db.query_ary("select * from f where f match 'drinks'"), q.bind("coffee").to_a, StringScanner.new("ab").scan(/a/)]; q.close; db.close; res
rescue Exception => e
  "ERR #{e.class}: #{e.message}"
end
p r.value

# cross-ractor push into an Async reactor, via a thread inside the ractor
w = Ractor.new do
  inbox = Thread::Queue.new
  port = Ractor::Port.new
  Ractor.main.send([:port, port]) rescue nil
  Thread.new { loop { inbox << port.receive } }
  got = []
  Async do |task|
    task.async { 3.times { got << inbox.pop } }
    task.async { 10.times { |i| sleep 0.01 } ; got << :ticks_done }
  end
  got
end

port = Ractor.receive.last
port << "a"; port << "b"; port << "c"
p w.value

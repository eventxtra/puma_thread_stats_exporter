require 'webrick'
require 'json'

class PumaThreadStatsExporter
  attr_reader :bind
  attr_reader :port
  attr_reader :resolution
  attr_reader :metrics_prefix

  def initialize(bind: nil, port: nil, resolution: nil, metrics_prefix: nil)
    @bind = bind || ENV['PUMA_THREAD_STATS_EXPORTER_BIND'] || '0.0.0.0'
    @port = port || ENV['PUMA_THREAD_STATS_EXPORTER_PORT'] || '9394'
    @resolution = (
      resolution ||
      (Float(ENV['PUMA_THREAD_STATS_EXPORTER_RESOLUTION']) rescue nil) ||
      1
    )
    @metrics_prefix = (
      metrics_prefix || ENV['PUMA_THREAD_STATS_EXPORTER_PREFIX'] || 'puma'
    )
  end

  def listen
    @server = WEBrick::HTTPServer.new(
      Port: @port,
      BindAddress: @bind,
      Logger: WEBrick::Log.new("/dev/null"),
      AccessLog: WEBrick::Log.new("/dev/null")
    )

    @server.mount_proc '/' do |req, res|
      case req.path
      when '/metrics'
        handle_metrics(req, res)
      when '/readiness'
        handle_readiness(req, res)
      else
        res.status = 404
        res.body = 'Not found. The exporter server only listens on /metrics or /readiness'
      end
    end

    Thread.new { @server.start }
  end

  private

  attr_reader :cached_at
  attr_reader :cached_stats

  def handle_metrics(_req, res)
    if stats.nil?
      res.status = 503
      res.body = 'Metrics to export are unavailable at the moment.'  
    else
      max_threads = stats[:max_threads]
      ready_threads = stats[:ready_threads]

      res.status = 200
      res.body = [
        "#{metrics_prefix}_max_threads#{metrics_labels} #{max_threads}",
        "#{metrics_prefix}_ready_threads#{metrics_labels} #{ready_threads}"
      ].join("\n")
    end
  end

  def handle_readiness(_req, res)
    if puma_pool_ready?
      res.status = 200
      res.body = 'OK'
    else
      res.status = 503
      res.body = 'Unready'
    end
  end

  def stats
    refresh_stats? ? refresh_stats : cached_stats
  end

  def refresh_stats
    @cached_at = Time.now

    stats = JSON.parse(Puma.stats)
    worker_status = stats['worker_status']
    max_threads = worker_status.collect { |x| x['last_status']['max_threads'] }.sum
    ready_threads = worker_status.collect { |x| x['last_status']['pool_capacity'] }.sum

    @cached_stats = {
      max_threads: max_threads,
      ready_threads: ready_threads
    }
  rescue => e
    nil
  end

  def metrics_labels
    @metrics_labels ||= "{host=#{Socket.gethostname.to_json}}"
  end

  def refresh_stats?
    cached_at.nil? || (Time.now - cached_at) > resolution
  end

  def puma_pool_ready?
    stats && stats[:ready_threads] > 0
  end
end


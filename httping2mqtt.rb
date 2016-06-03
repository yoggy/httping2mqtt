#!/usr/bin/ruby
# coding: utf-8
#
# httping2mqtt.rb - simple web site monitoring script
#
# how to use:
#
#   $ mkdir ~/work
#   $ cd work
#   $ git clone git clone https://github.com/yoggy/httping2mqtt.git
#   $ cd httping2mqtt
#   $ cp mqtt_config.yaml.sample mqtt_config.yaml
#   $ vi mqtt_config.yaml
#
#       host:     mqtt.example.com
#       port:     1883
#       use_auth: true
#       username: username
#       password: password
#       interval: 300
#
#   $ cp target_url_config.yaml.sample target_url_config.yaml
#   $ vi larget_url_config.yaml
#
#       - target_url: http://www1.example.com/
#         dst_topic: topic/www1.example.com
#       
#       - target_url: http://www2.example.com/
#         dst_topic: topic/www2.example.com
#       
#       - target_url: http://www3.example.com/
#         dst_topic: topic/www3.example.com
#
#   $ ruby ./httping2mqtt.rb
#

require 'mqtt'
require 'yaml'
require 'json'
require 'open3'
require 'time'
require 'pp'

$stdout.sync = true

$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG

$mqtt_conf = YAML.load_file(File.dirname($0) + '/mqtt_config.yaml')
$target_url_conf = YAML.load_file(File.dirname($0) + '/target_url_config.yaml')

$http_connect_count = 3
$http_timeout = 10

def httping(target_url)
  httping = '/usr/bin/httping'
  cmd = "#{httping} -c #{$http_connect_count} -Z -t #{$http_timeout} #{target_url}"

  stdin, stdout, stderr, wait_thr = *Open3.popen3(cmd)
  wait_thr.join()
  
  connect_count  = 0
  ok_count       = 0
  ok_percent     = 0.0
  round_trip_min = Float::MAX
  round_trip_avg = Float::MAX
  round_trip_max = Float::MAX
  
  result = stdout.read
  result.each_line do |l|
    if l =~ /connects/
      s = l.scan(/(\d+) connects, (\d+) ok, (.+) failed, time (.+)/)
      connect_count = s[0][0].to_i
      ok_count      = s[0][1].to_i
      ok_percent    = ok_count / connect_count.to_f * 100.0
    end
    if l =~ /round-trip/
      s = l.scan(/round-trip min\/avg\/max = (.+)\/(.+)\/(.+) ms/)
      round_trip_min = s[0][0].to_f / 1000.0
      round_trip_avg = s[0][1].to_f / 1000.0 
      round_trip_max = s[0][2].to_f / 1000.0 
    end
  end
  
  h = {
    "time"           => Time.now.iso8601,
    "target_url"     => target_url,
    "connect_count"  => connect_count,
    "ok_count"       => ok_count,
    "ok_percent"     => ok_percent,
    "round_trip_min" => round_trip_min,
    "round_trip_avg" => round_trip_avg,
    "round_trip_max" => round_trip_max
  }
  h
end

def mqtt_publish(mqtt_client, topic, result)
  json_str = result.to_json
  $log.info json_str

  if mqtt_client != nil
    mqtt_client.publish(topic, json_str, true)
  end
end

def main_loop
  conn_opts = {
    "remote_host" => $mqtt_conf["host"],
    "remote_port" => $mqtt_conf["port"]
  }
  if $mqtt_conf["use_auth"]
    conn_opts["username"] = $mqtt_conf["username"]
    conn_opts["password"] = $mqtt_conf["password"]
  end

  $log.info "connecting..."
  MQTT::Client.connect(conn_opts) do |c|
    $log.info $target_url_conf
    $target_url_conf.each do |conf|
      result = httping(conf["target_url"])
      mqtt_publish(c, conf["dst_topic"], result)
    end
  end
end

begin
  loop do
    main_loop
    sleep $mqtt_conf["interval"].to_i
  end
rescue => e
  $log.error e
  sleep 5
  raise e
end


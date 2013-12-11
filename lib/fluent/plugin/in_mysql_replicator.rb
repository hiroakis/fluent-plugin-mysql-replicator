module Fluent
  class MysqlReplicatorInput < Fluent::Input
    Plugin.register_input('mysql_replicator', self)

    def initialize
      require 'mysql2'
      require 'digest/sha1'
      super
    end

    config_param :host, :string, :default => 'localhost'
    config_param :port, :integer, :default => 3306
    config_param :username, :string, :default => 'root'
    config_param :password, :string, :default => nil
    config_param :database, :string, :default => nil
    config_param :encoding, :string, :default => 'utf8'
    config_param :interval, :string, :default => '1m'
    config_param :query, :string
    config_param :primary_key, :string, :default => 'id'
    config_param :enable_delete, :bool, :default => 'yes'
    config_param :tag, :string, :default => nil

    def configure(conf)
      super
      @interval = Config.time_value(@interval)
      $log.info "adding mysql_replicator job: [#{@query}] interval: #{@interval}sec"

      if @tag.nil?
        raise Fluent::ConfigError, "mysql_replicator: missing 'tag' parameter. Please add following line into config like 'tag replicator.mydatabase.mytable.${event}.${primary_key}'"
      end
    end

    def start
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      Thread.kill(@thread)
    end

    def run
      begin
        poll
      rescue StandardError => e
        $log.error "error: #{e.message}"
        $log.error e.backtrace.join("\n")
      end
    end

    def poll
      table_hash = Hash.new
      ids = Array.new
      loop do
        previous_ids = ids
        current_ids = Array.new
        query(@query).each do |row|
          current_ids << row[@primary_key]
          current_hash = Digest::SHA1.hexdigest(row.flatten.join)
          row.each {|k, v| row[k] = v.to_s if v.is_a? Time}
          if !table_hash.include?(row[@primary_key])
            tag = format_tag(@tag, {:event => :insert})
            emit_record(tag, row)
          elsif table_hash[row[@primary_key]] != current_hash
            tag = format_tag(@tag, {:event => :update})
            emit_record(tag, row)
          end
          table_hash[row[@primary_key]] = current_hash
        end
        ids = current_ids
        unless @enable_delete
          deleted_ids = previous_ids - current_ids
          if deleted_ids.count > 0
            hash_delete_by_list(table_hash, deleted_ids)
            deleted_ids.each do |id| 
              tag = format_tag(@tag, {:event => :delete})
              emit_record(tag, {@primary_key => id})
            end
          end
        end
        sleep @interval
      end
    end

    def hash_delete_by_list (hash, deleted_keys)
      deleted_keys.each{|k| hash.delete(k)}
    end

    def format_tag(tag, param)
      pattern = {'${event}' => param[:event].to_s, '${primary_key}' => @primary_key}
      tag.gsub(/\${[a-z_]+(\[[0-9]+\])?}/, pattern) do
        $log.warn "mysql_replicator: missing placeholder. tag:#{tag} placeholder:#{$1}" unless pattern.include?($1)
        pattern[$1]
      end
    end

    def emit_record(tag, record)
      Engine.emit(tag, Engine.now, record)
    end

    def query(query)
      @mysql ||= get_connection
      begin
        return @mysql.query(query, :cast => false, :cache_rows => false)
      rescue Exception => e
        $log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end

    def get_connection
      begin
        return Mysql2::Client.new({
          :host => @host,
          :port => @port,
          :username => @username,
          :password => @password,
          :database => @database,
          :encoding => @encoding,
          :reconnect => true,
          :stream => true,
          :cache_rows => false
        })
      rescue Exception => e
        $log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end
  end
end

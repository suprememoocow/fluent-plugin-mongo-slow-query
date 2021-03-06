require 'json'

module Fluent
    class MongoDBSlowQueryInput < TailInput
        # First, register the plugin. NAME is the name of this plugin
        # and identifies the plugin in the configuration file.
        Plugin.register_input('mongo_slow_query', self)

        # This method is called before starting.
        # 'conf' is a Hash that includes configuration parameters.
        # If the configuration is invalid, raise Fluent::ConfigError.
        def configure(conf)
            #unless conf.has_key?("format")
            #    conf["format"] = '/(?<time>.*) \[\w+\] (?<op>[^ ]+) (?<ns>[^ ]+) (?<detail>((query: (?<query>{.+}) update: {.*})|(query: (?<query>{.+})))) .* (?<ms>\d+)ms/'
            #    $log.warn "load default format: ", conf["format"]
            #end

            # load default format that degisned for MongoDB
            conf["format"] = '/^(?<time>[^ ]+) \[\w+\] (?<op>\w+) (?<ns>[\w-]+\.[\-\w\$]+)(?: (?<command>[\-\w\$]+): (?:(?<commandDetail>\w+) )?(?:(?:(?<query>\{.*\}) planSummary: (?<planSummary>\w+(?: \{.*\})?)?|(?<query>\{.*\}))))?(?: (?:nscanned:(?<nscanned>\d+)|nMatched:(?<nMatched>\d+)|nModified:(?<nModified>\d+)|numYields:(?<numYields>\d+)|reslen:(?<reslen>\d+)|\w+:\d+|locks\(micros\)(?: (?:r:(?<lockread>\d+)|w:(?<lockwrite>\d+)|R:(?<lockglobread>\d+)|W:(?<lockglobwrite>\d+)|\w:\d+))))* (?<ms>\d+)ms$/'

            # not set "time_format"
            # default use Ruby's DateTime.parse() to pase time
            #
            # be compatible for v2.2, 2.4 and 2.6
            # difference of time format
            # 2.2: Wed Sep 17 10:00:00 [conn] ...
            # 2.4: Wed Sep 17 10:00:00.123 [conn] ...
            # 2.6: 2014-09-17T10:00:43.506+0800  [conn] ...
            #unless conf.has_key?("time_format")
            #    #conf["time_format"] = '%a %b %d %H:%M:%S'
            #    #conf["time_format"] = '%a %b %d %H:%M:%S.%L'
            #    #$log.warn "load default time_format: ", conf["time_format"]
            #end
            super
        end

        def receive_lines(lines)
            es = MultiEventStream.new
            lines.each {|line|
                begin
                    line.chomp!  # remove \n
                    time, record = parse_line(line)
                    if time && record
                        record["query"] = get_query_prototype(record["query"]) if record["query"]
                        record["ms"] = record["ms"].to_i
                        record["ts"] = time

                        record["nscanned"] = record["nscanned"].to_i if record["nscanned"]
                        record["nMatched"] = record["nMatched"].to_i if record["nMatched"]
                        record["nModified"] = record["nModified"].to_i if record["nModified"]
                        record["numYields"] = record["numYields"].to_i if record["numYields"]
                        record["reslen"] = record["reslen"].to_i if record["reslen"]
                        record["lockread"] = record["lockread"].to_f / 1000 if record["lockread"]
                        record["lockwrite"] = record["lockwrite"].to_f  / 1000 if record["lockwrite"]
                        record["lockglobread"] = record["lockglobread"].to_f  / 1000 if record["lockglobread"]
                        record["lockglobwrite"] = record["lockglobwrite"].to_f  / 1000 if record["lockglobwrite"]

                        #if record.has_key?("update")
                        #    record["update"] = get_query_prototype(record["update"])
                        #end
                        es.add(time, record)
                    end
                rescue
                    $log.warn line.dump, :error=>$!.to_s
                    $log.debug_backtrace
                end
            }

            unless es.empty?
                begin
                    Engine.emit_stream(@tag, es)
                rescue
                    #ignore errors. Engine shows logs and backtraces.
                end
            end
        end

        # extract query prototype recursively
        def extract_query_prototype(query_json_obj, parent='')
            ns_array = []
            query_json_obj.each do |key, val|
                ns = parent.empty? ? key : (parent + '.' + key)
                if val.class == Hash
                    ns_array += extract_query_prototype(val, ns)
                elsif val.class == Array
                    val.each do |item|
                        if item.class == Hash
                            ns_array += extract_query_prototype(item, ns)
                        else
                            ns_array << ns + '.' + item
                        end
                    end
                else
                    ns_array << ns
                end
            end
            return ns_array
        end

        # get query prototype
        def get_query_prototype(query)
            begin
                prototype = extract_query_prototype(JSON.parse(to_json(query)))
                return '{ ' + prototype.join(', ') + ' }'
            rescue
                $log.warn $!.to_s
                return query
            end
        end

        # convert query to JSON
        def to_json(query)
            res = query
            # conversion for fieldname
            res = res.gsub(/( [^ ]+?: )/) {|fieldname| fieldname_format(fieldname)}
            # conversion for ObjectId
            res = res.gsub(/ObjectId\([^ ]+?\)/) {|objectid| to_string(objectid)}
            # conversion for Timestamp
            res = res.gsub(/Timestamp \d+\|\d+/) {|timestamp| to_string(timestamp)}
            # conversion for Date
            res = res.gsub(/new Date\(\d+\)/) {|date| to_string(date)}
            # filter regex
            res = res.gsub(/\/\^.*\//) {|pattern| to_string(pattern)}
            return res
        end

        # format fieldname in query
        # e.g.: { id: 1 } => { "id": 1 }
        def fieldname_format(fieldname)
            return ' "%s": ' % fieldname.strip.chomp(':')
        end

        # convert value of special type to string
        # so that convert query to json
        def to_string(str)
            res = str
            res = res.gsub(/"/, '\"')
            res = '"%s"' % res
            return res
        end
    end
end

class Log < ApplicationRecord
  include Helper
  before_create :unique_log_entry

  def unique_log_entry
    !!!Log.find_by(
      component_name: self.component_name,
      component_type: self.component_type,
      location: self.location,
      status: self.status,
      change_ts: self.change_ts
    )
  end

  def self.min_and_max_dates

    sql = <<-SQL
      SELECT DISTINCT
        MIN(change_ts) AS min_date,
        MAX(change_ts) AS max_date
      FROM logs
    SQL

    results = Log.find_by_sql [sql]
    [results[0].min_date, results[0].max_date]
  end

  def self.unique_components
    sql = <<-SQL
      SELECT DISTINCT
        logs.component_name,
        logs.component_type
      FROM logs
    SQL

    Log.find_by_sql [sql]
  end

  def self.unique_component_types
    sql = <<-SQL
      SELECT DISTINCT
        logs.component_type
      FROM logs
      ORDER BY logs.component_type
    SQL

    results = Log.find_by_sql [sql]
    results.map{|x| x.component_type}
  end

  def self.unique_component_types_by_location(location)
    sql = <<-SQL
      SELECT DISTINCT
        logs.component_type
      FROM logs
      WHERE location = ?
    SQL

    results = Log.find_by_sql [sql, location]
    results.map{|x| x.component_type}

  end

  def self.unique_locations
    sql = <<-SQL
      SELECT DISTINCT
        logs.location
      FROM logs
    SQL

    results = Log.find_by_sql [sql]
    results.map{|x| x.location}
  end

  def self.unique_statuses
    sql = <<-SQL
      SELECT DISTINCT
        logs.status
      FROM logs
    SQL

    Log.find_by_sql [sql]
  end

  def self.first_status(component_name = "COMPONENT000000001")
    sql = <<-SQL
      SELECT DISTINCT
        logs.id,
        logs.component_name,
        logs.component_type,
        logs.location,
        logs.status,
        MIN(logs.change_ts) min_change_ts
      FROM logs
      WHERE
        logs.component_name = ?
      GROUP BY logs.component_name
    SQL

    results = Log.find_by_sql [sql, component_name]
    results.map(&:attributes)
  end

  def self.last_status(component_name = "COMPONENT000000001")
    sql = <<-SQL
      SELECT DISTINCT
        logs.id,
        logs.component_name,
        logs.component_type,
        logs.location,
        logs.status,
        MAX(logs.change_ts) max_change_ts
      FROM logs
      WHERE
        logs.component_name = ?
      GROUP BY logs.component_name
    SQL

    results = Log.find_by_sql [sql, component_name]
    results.map(&:attributes)
  end

  def self.minutes_to_completion(component_name = "COMPONENT000000001")
    sql = <<-SQL
      SELECT DISTINCT
        logs.id,
        logs.component_name,
        logs.component_type,
        MIN(logs.change_ts) AS min_change_ts,
        MAX(logs.change_ts) AS max_change_ts,
        (JULIANDAY(MAX(logs.change_ts)) - JULIANDAY(MIN(logs.change_ts))) * 24 * 60 AS minutes_to_completion
      FROM logs
      WHERE
        logs.component_name = ?
      GROUP BY logs.component_name
    SQL

    results = Log.find_by_sql [sql, component_name]
    results.map(&:attributes)
  end

  # BY COMPONENT TYPE

  def self.mean_completion_time_by_component_type(format = "day")

    multiplier = Helper.time_multiplier(format)

    connection = ActiveRecord::Base.connection

    connection.execute("DROP TABLE IF EXISTS temp")

    temp_sql = <<-SQL
      SELECT DISTINCT
        component_name,
        component_type,
        (JULIANDAY(MAX(logs.change_ts)) - JULIANDAY(MIN(logs.change_ts))) * #{multiplier} AS time_to_completion
      FROM logs
      GROUP BY component_name
      HAVING time_to_completion > 0;
    SQL

    connection.create_table(:temp, temporary: true, as: temp_sql)

    sql = <<-SQL
      SELECT DISTINCT
        component_type,
        AVG(time_to_completion) AS "average_completion_time"
      FROM temp
      GROUP BY component_type;
    SQL


    results = Log.find_by_sql [sql]
    results.map(&:attributes)
  end

  def self.query_component_steps(component_type = nil)
    # connection = ActiveRecord::Base.connection
    #
    # connection.execute("DROP TABLE IF EXISTS temp")

    # temp_sql = <<-SQL
    # CREATE TEMPORARY TABLE temp (
    #   id INTEGER PRIMARY KEY ASC,
    #   component_name TEXT,
    #   component_type TEXT,
    #   location TEXT,
    #   status TEXT,
    #   change_ts DATETIME
    # );
    #
    # INSERT INTO temp (component_name, component_type, location, status, change_ts)
    #   SELECT
    #   logs.component_name,
    #   logs.component_type,
    #   logs.location,
    #   logs.status,
    #   logs.change_ts
    #   FROM logs
    #   WHERE status IN ("in progress", "complete")
    #   ORDER BY logs.component_name, logs.change_ts;
    #
    # SQL


    # temp_sql = <<-SQL
    #   SELECT DISTINCT
    #     component_name,
    #     component_type,
    #     location,
    #     status,
    #     change_ts
    #   FROM logs
    #   WHERE status IN ("in progress", "complete")
    #   ORDER BY logs.component_name, logs.change_ts;
    # SQL
    #
    # connection.create_table(:temp, temporary: true, as: temp_sql)

    if component_type
      sql = <<-SQL
        SELECT DISTINCT
          logs.component_name,
          component_type,
          location,
          status,
          change_ts
        FROM logs
        INNER JOIN (
          SELECT DISTINCT
            component_name
          FROM logs
          WHERE component_type = ?
          AND status IN ("in progress", "complete")
          ORDER BY component_name, change_ts
          LIMIT 1
        ) first
        ON logs.component_name = first.component_name
      SQL

      Log.find_by_sql [sql, component_type]
    else
      sql = <<-SQL
        SELECT DISTINCT
          component_name,
          component_type,
          location,
          status,
          change_ts
        FROM logs
        WHERE status IN ("in progress", "complete")
        ORDER BY component_name, change_ts
      SQL

      Log.find_by_sql [sql]
    end
  end

  def self.manufacturing_process_by_component_type
    unique_component_types = Log.unique_component_types
    result = unique_component_types.inject({}) do |obj, component_type|
      obj[component_type] = []
      obj
    end

    unique_component_types.each do |component_type|
      Log.query_component_steps(component_type).each do |step|
        result[component_type] << step.location
      end
    end
    result
  end



  def self.rate_of_output_per_component_type(format = "day")
    multiplier = Helper.time_multiplier(format)
    dates = Log.min_and_max_dates
    date_diff = (Date.parse(dates[1]) - Date.parse(dates[0])).to_f * multiplier
    sql = <<-SQL
      SELECT DISTINCT
        logs.component_type,
        COUNT(logs.component_name) AS total_components,
        (COUNT(logs.component_type) / ?) AS "total_components_per_time"
      FROM logs
      WHERE logs.status = 'complete'
      GROUP BY logs.component_type
    SQL

    results = Log.find_by_sql [sql, date_diff]
    results.map(&:attributes)
  end

  def self.waiting_time_stats_by_component(format = "day")
    divisor = Helper.time_divisor(format)

    sql = <<-SQL
      SELECT DISTINCT
      component_name,
      component_type,
      location,
      status,
      change_ts
      FROM logs
      ORDER BY component_name, change_ts
    SQL

    query_results = Log.find_by_sql [sql]

    result = Log.unique_component_types.inject([]) do |arr, component|
      arr.push({"component_type" => component, "total_wait_time" => 0, "average_total_wait_time" => 0, "all_wait_times" =>[]})
      arr
    end

    previous = query_results[0]
    counter = 1

    while counter < query_results.length
      current = query_results[counter]

      current_component = result.find{|x| x["component_type"] == current.component_type}
      if previous.component_name != current.component_name && (previous.status == "waiting" && current.status == "in progress")
        previous = query_results[counter]
        counter += 1
        next
      end

      if previous.status == "waiting" && current.status == "in progress"
        change = (current.change_ts - previous.change_ts) / divisor
        current_component["total_wait_time"] += change
        current_component["all_wait_times"] << {"component_type" => current.component_type, "wait_time" => change}
        current_component["average_total_wait_time"] = current_component["total_wait_time"] / current_component["all_wait_times"].size
      end

      previous = query_results[counter]
      counter += 1

    end

    result

  end

  #BY LOCATION

  def self.rate_of_output_by_location(format = "day")
    multiplier = Helper.time_multiplier(format)
    dates = Log.min_and_max_dates
    date_diff = (Date.parse(dates[1]) - Date.parse(dates[0])).to_f * multiplier
    sql = <<-SQL
      SELECT DISTINCT
        logs.location,
        COUNT(*) AS total_components,
        (COUNT(*) / ?) AS "total_components_per_time"
      FROM logs
      WHERE logs.status = 'in progress'
      GROUP BY logs.location
    SQL

    results = Log.find_by_sql [sql, date_diff]
    results.map(&:attributes)
  end

  def self.mean_component_completion_time_by_location(format = "day")
    divisor = Helper.time_divisor(format)

    query_results = Log.query_component_steps

    result = Log.unique_locations.inject([]) do |arr, location|
      arr.push({"location" => location, "total_active_time" => 0, "average_time_to_complete_component" => 0, "all_completed_components" => []})
      # component_types = Log.unique_component_types_by_location(location)
      # obj[location] = component_types.inject({}) do |obj, component_type|
      #   obj[component_type] = []
      #   obj
      # end
      arr
    end

    previous = query_results[0]
    counter = 1


    while counter < query_results.length
      current = query_results[counter]
      previous_location = result.find{|x| x["location"] == previous.location}
      if previous.component_name != current.component_name
        previous = query_results[counter]
        counter += 1
        next
      end
      # puts "Current time: #{current.change_ts} location: #{current.location}"
      # puts "Previous time #{previous.change_ts} location: #{previous.location}"
      time = (current.change_ts - previous.change_ts) / divisor
      previous_location["total_active_time"] += time
      previous_location["all_completed_components"] << {"component_name" => previous.component_name, "component_type" => previous.component_type, "time" => time}
      previous_location["average_time_to_complete_component"] = previous_location["total_active_time"] / previous_location["all_completed_components"].size
      previous = query_results[counter]
      counter += 1
    end
    #
    # result.each do |location, component|
    #   component.each do |type, times|
    #     result[location][type] = times.inject{ |sum, el| sum + el }.to_f / times.size
    #   end
    # end

    # result = Log.unique_locations.inject({}) do |obj, location|
    #   component_types = Log.unique_component_types_by_location(location)
    #   obj[location] = component_types.inject({}) do |obj, component_type|
    #     obj[component_type] = []
    #     obj
    #   end
    #   obj
    # end
    #
    # previous = query_results[0]
    # counter = 1
    #
    #
    # while counter < query_results.length
    #   current = query_results[counter]
    #   if previous.component_name != current.component_name
    #     previous = query_results[counter]
    #     counter += 1
    #     next
    #   end
    #   # puts "Current time: #{current.change_ts} location: #{current.location}"
    #   # puts "Previous time #{previous.change_ts} location: #{previous.location}"
    #   result[previous.location][previous.component_type] << (current.change_ts - previous.change_ts) / divisor
    #   previous = query_results[counter]
    #   counter += 1
    # end
    #
    # result.each do |location, component|
    #   component.each do |type, times|
    #     result[location][type] = times.inject{ |sum, el| sum + el }.to_f / times.size
    #   end
    # end

    result
  end

  def self.query_location_steps(location = nil)
    if !location
      sql = <<-SQL
        SELECT DISTINCT
          location,
          component_name,
          component_type,
          status,
          change_ts
        FROM logs
        ORDER BY location, change_ts
      SQL

      results = Log.find_by_sql [sql]

    else
      sql = <<-SQL
        SELECT DISTINCT
          location,
          component_name,
          component_type,
          status,
          change_ts
        FROM logs
        WHERE location = ?
        ORDER BY location, change_ts
      SQL

      results = Log.find_by_sql [sql, location]
    end

    results
    # results.map(&:attributes)
  end

  def self.location_simultaneous_capacity
    # unique_locations = [Log.unique_locations[0]]
    unique_locations = Log.unique_locations

    result = unique_locations.inject([]) do |arr, location|
      arr << {"location" => location, "simultaneous_capacity" => 0}
      arr
    end

    unique_locations.each do |location|
      steps = Log.query_location_steps(location)
      counter = 0
      current = steps[0]
      initiates_manufacture = current.change_ts == Time.parse("2018-01-01 00:00:00 UTC")
      # while current && current.status == "in progress" && counter < steps.length
      while counter < steps.length && current.status == "in progress"
        current_location = current_location = result.find{|x| x["location"] == current.location}
        if initiates_manufacture && steps[counter + 1].change_ts != Time.parse("2018-01-01 00:00:00 UTC")
          current_location["simultaneous_capacity"] += 1
          break
        end
        current_location["simultaneous_capacity"] += 1
        counter += 1
        current = steps[counter]
      end
    end

    # result = unique_locations.inject({}) do |obj, location|
    #   obj[location] = 0
    #   obj
    # end
    #
    # unique_locations.each do |location|
    #   steps = Log.query_location_steps(location)
    #   counter = 0
    #   current = steps[0]
    #   initiates_manufacture = current.change_ts == Time.parse("2018-01-01 00:00:00 UTC")
    #   # while current && current.status == "in progress" && counter < steps.length
    #   while counter < steps.length && current.status == "in progress"
    #     if initiates_manufacture && steps[counter + 1].change_ts != Time.parse("2018-01-01 00:00:00 UTC")
    #       result[location] += 1
    #       break
    #     end
    #     result[location] += 1
    #     counter += 1
    #     current = steps[counter]
    #   end
    # end

    result

  end

  def self.location_capacity_per(format = "day")
    multiplier = Helper.time_multiplier(format)
    dates = Log.min_and_max_dates
    date_diff = (Date.parse(dates[1]) - Date.parse(dates[0])).to_f * multiplier
    sql = <<-SQL
      SELECT DISTINCT
        location,
        COUNT(*) / ? AS "capicity_per_#{format}"
      FROM logs
      WHERE status = "in progress"
      GROUP BY location
    SQL

    query_results = Log.find_by_sql [sql, date_diff]
    query_results.map(&:attributes)
    # results = query_results.inject({}) do |obj, row|
    #   obj[row.location] = row["capicity_per_#{format}"]
    #   obj
    # end
    #
    # results
  end

  def self.waiting_time_stats_by_location_old(format = "day")
    divisor = Helper.time_divisor(format)

    sql = <<-SQL
      SELECT DISTINCT
        component_name,
        component_type,
        location,
        status,
        change_ts
      FROM logs
      ORDER BY component_name, change_ts
    SQL

    query_results = Log.find_by_sql [sql]
    # result = Log.unique_locations.inject({}) do |obj, location|
    #   component_types = Log.unique_component_types_by_location(location)
    #   obj[location] = component_types.inject({}) do |obj, component_type|
    #     obj[component_type] = []
    #     obj
    #   end
    #   obj
    # end
    #
    # previous = query_results[0]
    # counter = 1
    #
    # while counter < query_results.length
    #   current = query_results[counter]
    #   if previous.component_name != current.component_name && (previous.status == "waiting" && current.status == "in progress")
    #     previous = query_results[counter]
    #     counter += 1
    #     next
    #   end
    #
    #   if previous.status == "waiting" && current.status == "in progress"
    #     result[current.location][current.component_type] << (current.change_ts - previous.change_ts) / divisor
    #   end
    #
    #   previous = query_results[counter]
    #   counter += 1
    #
    # end
    #
    # result.each do |location, component|
    #   result[location]["total_wait_time"] = 0
    #   size = 0
    #   component.each do |type, times|
    #     if times.instance_of?(Array) && times.length != 0
    #       size += times.length
    #       total = times.inject{ |sum, el| sum + el }.to_f
    #       result[location]["total_wait_time"] += total
    #       result[location][type] = total / times.length
    #     elsif type.include? "component"
    #       result[location][type] = 0
    #     end
    #   end
    #
    #   if size > 0
    #     result[location]["average_total_wait_time"] = result[location]["total_wait_time"] / size
    #   else
    #     result[location]["average_total_wait_time"] = 0
    #   end
    # end

    result
  end

  def self.waiting_time_stats_by_location(format = "day")
    divisor = Helper.time_divisor(format)

    sql = <<-SQL
      SELECT DISTINCT
      component_name,
      component_type,
      location,
      status,
      change_ts
      FROM logs
      ORDER BY component_name, change_ts
    SQL

    query_results = Log.find_by_sql [sql]

    result = Log.unique_locations.inject([]) do |arr, location|
      arr.push({"location" => location, "total_wait_time" => 0, "average_total_wait_time" => 0, "all_wait_times" => []})
      arr
    end

    previous = query_results[0]
    counter = 1

    while counter < query_results.length
      current = query_results[counter]

      current_location = result.find{|x| x["location"] == current.location}
      if previous.component_name != current.component_name && (previous.status == "waiting" && current.status == "in progress")
        previous = query_results[counter]
        counter += 1
        next
      end

      if previous.status == "waiting" && current.status == "in progress"
        change = (current.change_ts - previous.change_ts) / divisor
        # byebug
        current_location["total_wait_time"] += change
        current_location["all_wait_times"] << {"component_type" => current.component_type, "wait_time" => change}
        current_location["average_total_wait_time"] = current_location["total_wait_time"] / current_location["all_wait_times"].size
      end

      previous = query_results[counter]
      counter += 1

    end

    result
  end



  def self.unit_output_per(format = "day")
    # Since each unit requires all 4 components, then the amount of units produced is bound by the slowest produced component
    component_output = Log.rate_of_output_per_component_type(format)

    result = Float::INFINITY
    component_output.each do |output|
      if output["total_components_per_#{format}"] < result
        result = output["total_components_per_#{format}"]
      end
    end

    result
  end

end

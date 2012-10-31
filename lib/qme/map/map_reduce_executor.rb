module QME

  module MapReduce

    # Computes the value of quality measures based on the current set of patient
    # records in the database
    class Executor

      include DatabaseAccess

      # Create a new Executor for a specific measure, effective date and patient population.
      # @param [String] measure_id the measure identifier
      # @param [String] sub_id the measure sub-identifier or null if the measure is single numerator
      # @param [Hash] parameter_values a hash that may contain the following keys: 'effective_date' the measurement period end date, 'test_id' an identifier for a specific set of patients
      def initialize(measure_id, sub_id, parameter_values)
        @measure_id = measure_id
        @sub_id = sub_id
        @parameter_values = parameter_values
        @measure_def = QualityMeasure.new(@measure_id, @sub_id).definition
        determine_connection_information()
      end

      # Examines the patient_cache collection and generates a total of all groups
      # for the measure. The totals are placed in a document in the query_cache
      # collection.
      # @return [Hash] measure groups (like numerator) as keys, counts as values
      def count_records_in_measure_groups
        pipeline = []
        base_query = {'value.measure_id' => @measure_id, 'value.sub_id' => @sub_id,
                      'value.effective_date' => @parameter_values['effective_date'],
                      'value.test_id' => @parameter_values['test_id']}

        base_query.merge!(filter_parameters)
        
        query = base_query.clone

        query.merge!({'value.manual_exclusion' => {'$in' => [nil, false]}})

        pipeline << {'$match' => query}
        pipeline << {'$group' => {
          "_id" => "$value.measure_id", # we don't really need this, but Mongo requires that we group 
          "population" => {"$sum" => "$value.population"}, 
          "denominator" => {"$sum" => "$value.denominator"},
          "numerator" => {"$sum" => "$value.numerator"},
          "antinumerator" => {"$sum" => "$value.antinumerator"},
          "exclusions" => {"$sum" => "$value.exclusions"},
          "denexcep" => {"$sum" => "$value.denexcep"},
          "considered" => {"$sum" => 1}
        }}
        
        aggregate = get_db.command(:aggregate => 'patient_cache', :pipeline => pipeline)
        if aggregate['ok'] != 1
          raise RuntimeError, "Aggregation Failed"
        elsif aggregate['result'].size !=1
          raise RuntimeError, "Expected one group from patient_cache aggregation, got #{aggregate['result'].size}"
        end

        nqf_id = @measure_def['nqf_id'] || @measure_def['id']
        result = {:measure_id => @measure_id, :sub_id => @sub_id, :nqf_id => nqf_id, :population_ids => @measure_def["population_ids"],
                  :effective_date => @parameter_values['effective_date'],
                  :test_id => @parameter_values['test_id'], :filters => @parameter_values['filters']}

        result.merge!(aggregate['result'].first)
        result.reject! {|k, v| k == '_id'} # get rid of the group id the Mongo forced us to use
        result['exclusions'] += get_db['patient_cache'].find(base_query.merge({'value.manual_exclusion'=>true})).count
        result.merge!(execution_time: (Time.now.to_i - @parameter_values['start_time'].to_i)) if @parameter_values['start_time']
        get_db()["query_cache"].insert(result)
        get_db().command({:getLastError => 1}) # make sure last insert finished before we continue
        result
      end

      # This method runs the MapReduce job for the measure which will create documents
      # in the patient_cache collection. These documents will state the measure groups
      # that the record belongs to, such as numerator, etc.
      def map_records_into_measure_groups
        measure = Builder.new(get_db(), @measure_def, @parameter_values)
        get_db().command(:mapReduce => 'records',
                         :map => measure.map_function,
                         :reduce => "function(key, values){return values;}",
                         :out => {:reduce => 'patient_cache'}, 
                         :finalize => measure.finalize_function,
                         :query => {:test_id => @parameter_values['test_id']})
        apply_manual_exclusions
      end
      
      # This method runs the MapReduce job for the measure and a specific patient.
      # This will create a document in the patient_cache collection. This document
      # will state the measure groups that the record belongs to, such as numerator, etc.
      def map_record_into_measure_groups(patient_id)
        measure = Builder.new(get_db(), @measure_def, @parameter_values)
        get_db().command(:mapReduce => 'records',
                         :map => measure.map_function,
                         :reduce => "function(key, values){return values;}",
                         :out => {:reduce => 'patient_cache'}, 
                         :finalize => measure.finalize_function,
                         :query => {:medical_record_number => patient_id, :test_id => @parameter_values['test_id']})
        apply_manual_exclusions
      end
      
      # This method runs the MapReduce job for the measure and a specific patient.
      # This will *not* create a document in the patient_cache collection, instead the
      # result is returned directly.
      def get_patient_result(patient_id)
        measure = Builder.new(get_db(), @measure_def, @parameter_values)
        result = get_db().command(:mapReduce => 'records',
                                  :map => measure.map_function,
                                  :reduce => "function(key, values){return values;}",
                                  :out => {:inline => true}, 
                                  :raw => true, 
                                  :finalize => measure.finalize_function,
                                  :query => {:medical_record_number => patient_id, :test_id => @parameter_values['test_id']})
        raise result['err'] if result['ok']!=1
        result['results'][0]['value']
      end
      
      # This collects the set of manual exclusions from the manual_exclusions collections
      # and sets a flag in each cached patient result for patients that have been excluded from the
      # current measure
      def apply_manual_exclusions
        exclusions = get_db()['manual_exclusions'].find({'measure_id'=>@measure_id, 'sub_id'=>@sub_id}).to_a.map do |exclusion|
          exclusion['medical_record_id']
        end
        get_db()['patient_cache'].find({'value.measure_id'=>@measure_id, 'value.sub_id'=>@sub_id, 'value.medical_record_id'=>{'$in'=>exclusions} })
          .update_all({'$set'=>{'value.manual_exclusion'=>true}})
      end

      def filter_parameters
        results = {}
        conditions = []
        if(filters = @parameter_values['filters'])
          if (filters['providers'] && filters['providers'].size > 0)
            providers = filters['providers'].map {|provider_id| Moped::BSON::ObjectId(provider_id) if (provider_id and provider_id != 'null') }
            # provider_performances have already been filtered by start and end date in map_reduce_builder as part of the finalize
            conditions << {'value.provider_performances.provider_id' => {'$in' => providers}}
          end
          if (filters['races'] && filters['races'].size > 0)
            conditions << {'value.race.code' => {'$in' => filters['races']}}
          end
          if (filters['ethnicities'] && filters['ethnicities'].size > 0)
            conditions << {'value.ethnicity.code' => {'$in' => filters['ethnicities']}}
          end
          if (filters['genders'] && filters['genders'].size > 0)
            conditions << {'value.gender' => {'$in' => filters['genders']}}
          end
          if (filters['languages'] && filters['languages'].size > 0)
            languages = filters['languages'].clone
            has_unspecified = languages.delete('null')
            or_clauses = []
            or_clauses << {'value.languages'=>{'$regex'=>Regexp.new("(#{languages.join("|")})-..")}} if languages.length > 0
            or_clauses << {'value.languages'=>nil} if (has_unspecified)
            conditions << {'$or'=>or_clauses}
          end
        end
        results.merge!({'$and'=>conditions}) if conditions.length > 0
        results
      end
    end
  end
end

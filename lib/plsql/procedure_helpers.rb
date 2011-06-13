module PLSQL
  
  module ProcedureHelperProvider
    
    def procedure_helper(dialect)
      case dialect
      when :oracle
        ORAProcedureHelper
      when :postgres
        PGProcedureHelper
      end
    end
    
  end
  
  module ProcedureHelper
    
    module ClassMethods
    
      def find(schema, procedure, package = nil, override_schema_name = nil)
        case schema.connection.dialect
        when :oracle
          if package.nil?
            if (row = schema.select_first(
                  "SELECT object_id FROM all_objects
                  WHERE owner = :owner
                  AND object_name = :object_name
                  AND object_type IN ('PROCEDURE','FUNCTION')",
                  schema.schema_name, procedure.to_s.upcase))
              new(schema, procedure, nil, nil, row[0])
              # search for synonym
            elsif (row = schema.select_first(
                  "SELECT o.owner, o.object_name, o.object_id
                  FROM all_synonyms s, all_objects o
                  WHERE s.owner IN (:owner, 'PUBLIC')
                  AND s.synonym_name = :synonym_name
                  AND o.owner = s.table_owner
                  AND o.object_name = s.table_name
                  AND o.object_type IN ('PROCEDURE','FUNCTION')
                  ORDER BY DECODE(s.owner, 'PUBLIC', 1, 0)",
                  schema.schema_name, procedure.to_s.upcase))
              new(schema, row[1], nil, row[0], row[2])
            else
              nil
            end
          elsif package && (row = schema.select_first(
                # older Oracle versions do not have object_id column in all_procedures
                "SELECT o.object_id FROM all_procedures p, all_objects o
                WHERE p.owner = :owner
                AND p.object_name = :object_name
                AND p.procedure_name = :procedure_name
                AND o.owner = p.owner
                AND o.object_name = p.object_name
                AND o.object_type = 'PACKAGE'",
                override_schema_name || schema.schema_name, package, procedure.to_s.upcase))
            new(schema, procedure, package, override_schema_name, row[0])
          else
            nil
          end
        when :postgres
          if (row = schema.select_first(
                "SELECT routine_name FROM information_schema.routines
                WHERE UPPER(routine_schema) = '#{schema.schema_name}'
                AND UPPER(routine_name) = '#{procedure.to_s.upcase}'"))
            new(schema, procedure, nil, override_schema_name, row[0])
          end
        end
      end
      
    end
    
    def self.included(host_class)
      host_class.extend(ClassMethods)
    end
    
  end
  
  module ORAProcedureHelper
    
    attr_reader :arguments, :argument_list, :out_list, :return
    attr_reader :schema, :schema_name, :package, :procedure

    # get procedure argument metadata from data dictionary
    def get_argument_metadata #:nodoc:
      @arguments = {}
      @argument_list = {}
      @out_list = {}
      @return = {}
      @overloaded = false

      # store reference to previous level record or collection metadata
      previous_level_argument_metadata = {}

      # store tmp tables for each overload for table parameters with types defined inside packages
      @tmp_table_names = {}
      # store if tmp tables are created for specific overload
      @tmp_tables_created = {}

      # subprogram_id column is available just from version 10g
      subprogram_id_column = (@schema.connection.database_version <=> [10, 2, 0, 2]) >= 0 ? 'subprogram_id' : 'NULL'

      @schema.select_all(
        "SELECT #{subprogram_id_column}, object_name, TO_NUMBER(overload), argument_name, position, data_level,
              data_type, in_out, data_length, data_precision, data_scale, char_used,
              char_length, type_owner, type_name, type_subname
        FROM all_arguments
        WHERE object_id = :object_id
        AND owner = :owner
        AND object_name = :procedure_name
        ORDER BY overload, sequence",
        @object_id, @schema_name, @procedure
      ) do |r|

        subprogram_id, object_name, overload, argument_name, position, data_level,
          data_type, in_out, data_length, data_precision, data_scale, char_used,
          char_length, type_owner, type_name, type_subname = r

        @overloaded ||= !overload.nil?
        # if not overloaded then store arguments at key 0
        overload ||= 0
        @arguments[overload] ||= {}
        @return[overload] ||= nil
        @tmp_table_names[overload] ||= []

        sql_type_name = type_owner && "#{type_owner == 'PUBLIC' ? nil : "#{type_owner}."}#{type_name}#{type_subname ? ".#{type_subname}" : nil}"

        tmp_table_name = nil
        # type defined inside package
        if type_subname
          if collection_type?(data_type)
            raise ArgumentError, "#{data_type} type #{sql_type_name} definition inside package is not supported as part of other type definition," <<
              " use CREATE TYPE outside package" if data_level > 0
            # if subprogram_id was not supported by all_arguments view
            # then generate unique ID from object_name and overload
            subprogram_id ||= "#{object_name.hash % 10000}#{overload}"
            tmp_table_name = "#{Connection::RUBY_TEMP_TABLE_PREFIX}#{@schema.connection.session_id}_#{@object_id}_#{subprogram_id}_#{position}"
          elsif data_type != 'PL/SQL RECORD'
            # raise exception only when there are no overloaded procedure definitions
            # (as probably this overload will not be used at all)
            raise ArgumentError, "Parameter type #{sql_type_name} definition inside package is not supported, use CREATE TYPE outside package" if overload == 0
          end
        end

        argument_metadata = {
          :position => position && position.to_i,
          :data_type => data_type,
          :in_out => in_out,
          :data_length => data_length && data_length.to_i,
          :data_precision => data_precision && data_precision.to_i,
          :data_scale => data_scale && data_scale.to_i,
          :char_used => char_used,
          :char_length => char_length && char_length.to_i,
          :type_owner => type_owner,
          :type_name => type_name,
          :type_subname => type_subname,
          :sql_type_name => sql_type_name
        }
        if tmp_table_name
          @tmp_table_names[overload] << [(argument_metadata[:tmp_table_name] = tmp_table_name), argument_metadata]
        end

        if composite_type?(data_type)
          case data_type
          when 'PL/SQL RECORD'
            argument_metadata[:fields] = {}
          end
          previous_level_argument_metadata[data_level] = argument_metadata
        end

        # if function has return value
        if argument_name.nil? && data_level == 0 && in_out == 'OUT'
          @return[overload] = argument_metadata
          # if parameter
        else
          # top level parameter
          if data_level == 0
            # sometime there are empty IN arguments in all_arguments view for procedures without arguments (e.g. for DBMS_OUTPUT.DISABLE)
            @arguments[overload][argument_name.downcase.to_sym] = argument_metadata if argument_name
            # or lower level part of composite type
          else
            case previous_level_argument_metadata[data_level - 1][:data_type]
            when 'PL/SQL RECORD'
              previous_level_argument_metadata[data_level - 1][:fields][argument_name.downcase.to_sym] = argument_metadata
            when 'PL/SQL TABLE', 'TABLE', 'VARRAY', 'REF CURSOR'
              previous_level_argument_metadata[data_level - 1][:element] = argument_metadata
            end
          end
        end
      end
      # if procedure is without arguments then create default empty argument list for default overload
      @arguments[0] = {} if @arguments.keys.empty?

      construct_argument_list_for_overloads
    end

    def construct_argument_list_for_overloads #:nodoc:
      @overloads = @arguments.keys.sort
      @overloads.each do |overload|
        @argument_list[overload] = @arguments[overload].keys.sort {|k1, k2| @arguments[overload][k1][:position] <=> @arguments[overload][k2][:position]}
        @out_list[overload] = @argument_list[overload].select {|k| @arguments[overload][k][:in_out] =~ /OUT/}
      end
    end

    def ensure_tmp_tables_created(overload) #:nodoc:
      return if @tmp_tables_created.nil? || @tmp_tables_created[overload]
      @tmp_table_names[overload] && @tmp_table_names[overload].each do |table_name, argument_metadata|
        sql = "CREATE GLOBAL TEMPORARY TABLE #{table_name} (\n"
        element_metadata = argument_metadata[:element]
        case element_metadata[:data_type]
        when 'PL/SQL RECORD'
          fields_metadata = element_metadata[:fields]
          fields_sorted_by_position = fields_metadata.keys.sort_by{|k| fields_metadata[k][:position]}
          sql << fields_sorted_by_position.map do |field|
            metadata = fields_metadata[field]
            "#{field} #{ProcedureCommon.type_to_sql(metadata)}"
          end.join(",\n")
        else
          sql << "element #{ProcedureCommon.type_to_sql(element_metadata)}"
        end
        sql << ",\ni__ NUMBER(38)\n"
        sql << ") ON COMMIT PRESERVE ROWS\n"
        sql_block = "DECLARE\nPRAGMA AUTONOMOUS_TRANSACTION;\nBEGIN\nEXECUTE IMMEDIATE :sql;\nEND;\n"
        @schema.execute sql_block, sql
      end
      @tmp_tables_created[overload] = true
    end

    PLSQL_COMPOSITE_TYPES = ['PL/SQL RECORD', 'PL/SQL TABLE', 'TABLE', 'VARRAY', 'REF CURSOR'].freeze
    def composite_type?(data_type) #:nodoc:
      PLSQL_COMPOSITE_TYPES.include? data_type
    end

    PLSQL_COLLECTION_TYPES = ['PL/SQL TABLE', 'TABLE', 'VARRAY'].freeze
    def collection_type?(data_type) #:nodoc:
      PLSQL_COLLECTION_TYPES.include? data_type
    end

    def overloaded? #:nodoc:
      @overloaded
    end
    
  end
  
  module PGProcedureHelper
    
    def get_argument_metadata #:nodoc:
      
    end
    
  end
  
end
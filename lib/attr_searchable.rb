
require "attr_searchable/version"
require "attr_searchable/arel"
require "attr_searchable_grammar"
require "attr_searchable/hash_parser"
require "treetop"

Treetop.load File.expand_path("../attr_searchable_grammar.treetop", __FILE__)

module AttrSearchable
  class SpecificationError < StandardError; end
  class UnknownAttribute < SpecificationError; end

  class RuntimeError < StandardError; end
  class UnknownColumn < RuntimeError; end
  class NoSearchableAttributes < RuntimeError; end
  class IncompatibleDatatype < RuntimeError; end
  class ParseError < RuntimeError; end

  module Parser
    def self.parse(query, model)
      query.is_a?(Hash) ? parse_hash(query, model) : parse_string(query, model)
    end

    def self.parse_hash(hash, model)
      AttrSearchable::HashParser.new(model).parse(hash) || raise(ParseError)
    end

    def self.parse_string(string, model)
      node = AttrSearchableGrammarParser.new.parse(string) || raise(ParseError)
      node.model = model
      node.evaluate
    end
  end

  def self.included(base)
    base.class_attribute :searchable_attributes
    base.searchable_attributes = {}

    base.class_attribute :searchable_attribute_options
    base.searchable_attribute_options = {}

    base.class_attribute :searchable_attribute_aliases
    base.searchable_attribute_aliases = {}

    base.extend ClassMethods
  end

  module ClassMethods
    def attr_searchable(*args)
      args.each do |arg|
        attr_searchable_hash arg.is_a?(Hash) ? arg : { arg => arg }
      end
    end

    def attr_searchable_hash(hash)
      hash.each do |key, value|
        self.searchable_attributes[key.to_s] = Array(value).collect do |column|
          table, attribute = column.to_s =~ /\./ ? column.to_s.split(".") : [name.tableize, column]

          "#{table}.#{attribute}"
        end
      end
    end

    def attr_searchable_options(key, options = {})
      self.searchable_attribute_options[key.to_s] = (searchable_attribute_options[key.to_s] || {}).merge(options)
    end

    def attr_searchable_alias(hash)
      hash.each do |key, value|
        self.searchable_attribute_aliases[key.to_s] = value.respond_to?(:table_name) ? value.table_name : value.to_s
      end
    end

    def default_searchable_attributes
      keys = searchable_attribute_options.select { |key, value| value[:default] == true }.keys
      keys = searchable_attributes.keys.reject { |key| searchable_attribute_options[key] && searchable_attribute_options[key][:default] == false } if keys.empty?
      keys = keys.to_set

      searchable_attributes.select { |key, value| keys.include? key }
    end

    def search(query)
      unsafe_search query
    rescue AttrSearchable::RuntimeError
      respond_to?(:none) ? none : where("1 = 0")
    end

    def unsafe_search(query)
      return respond_to?(:scoped) ? scoped : all if query.blank?

      associations = searchable_attributes.values.flatten.uniq.collect { |column| column.split(".").first }.collect { |column| searchable_attribute_aliases[column] || column.to_sym }

      scope = respond_to?(:search_scope) ? search_scope : nil
      scope ||= eager_load(associations - [name.tableize.to_sym])

      scope.where AttrSearchable::Parser.parse(query, self).optimize!.to_sql(self)
    end
  end
end


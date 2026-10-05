# frozen_string_literal: true

# Makes the Falcon/async stack usable from non-main Ractors.
#
# The gems keep configuration in constants (hashes, arrays, default instances)
# that are never mutated after load. Non-main Ractors may only read shareable
# constants, so after everything is loaded we deep-freeze them in place.
module RactorCompat
  ROOTS = %i[Async IO Protocol Falcon Console Fiber Traces Metrics].freeze

  module_function

  def share_constants!(extra_roots: [])
    seen = {}.compare_by_identity
    ROOTS.each do |name|
      next unless Object.const_defined?(name, false)
      walk(Object.const_get(name, false), seen)
    end
    extra_roots.each { |mod| walk(mod, seen) }
  end

  def walk(mod, seen)
    return if seen[mod]
    seen[mod] = true
    mod.instance_variables.each do |iv|
      v = mod.instance_variable_get(iv)
      next if v.nil? || Ractor.shareable?(v)
      begin
        Ractor.make_shareable(v)
      rescue => e
        warn "RactorCompat: #{mod}.#{iv} not shareable (#{e.class})" if $DEBUG
      end
    end
    mod.constants(false).each do |c|
      next if mod.autoload?(c)
      value = begin
        mod.const_get(c, false)
      rescue NameError, LoadError
        next
      end
      if value.is_a?(Module)
        walk(value, seen)
      elsif !Ractor.shareable?(value)
        begin
          Ractor.make_shareable(value)
        rescue => e
          warn "RactorCompat: #{mod}::#{c} not shareable (#{e.class})" if $DEBUG
        end
      end
    end
  end
end

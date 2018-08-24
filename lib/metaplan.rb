# frozen_string_literal: true

module MetaPlan
  extend self

  class ValidationError < StandardError; end

  VERSION = "0.1"

  SAFE_KEYS = /^(as|attach|partition|fallback|for_.*|.*_if)$/
  CONFIG_OPTS = {
    required_fields: %i[as attach],
    interpolate_step: nil,
    unpack_ref_container: nil,
    post_step: nil,
    merge_down_step: nil
  }.freeze

  def config(**config)
    @run_step = config[:run_step]
    raise "undefined :run_step in config" if @run_step.nil?
    CONFIG_OPTS.each do |opt, init_value|
      instance_variable_set("@#{opt}", init_value)
      next unless config.key?(opt)
      instance_variable_set("@#{opt}", config[opt])
    end
  end

  def run(plan:, state: {}, args: [])
    validate_plan(plan, state)

    step = shift_step(plan, state, args)
    step_result = @run_step.call(step, args)
    validate_result!(step, step_result)
    @post_step&.call(step, step_result)

    return next_step(plan, step_result) do |next_plan, content|
      next run(plan: next_plan, state: state.merge(step[:as] => content), args: args)
    end
  end

  def validate_plan(plan, state)
    @required_fields.each do |field|
      next if plan.key?(field)
      raise "plan does not include required field #{field.inspect}"
    end
    raise "#{plan[:as]} already exists from a previous step" if state.key?(plan[:as].to_sym)
  end

  def shift_step(plan, state, args)
    step = plan.dup
    step[:as] = step[:as].to_sym
    step.replace(step.map { |k, v| [k, unpack_and_apply!(state, k, v, args)] }.to_h)
    @interpolate_step&.call(step, state, args)

    return step
  end

  def unpack_and_apply!(state, key, value, args)
    return value if key.to_s =~ SAFE_KEYS || !value.is_a?(Hash) || !value.key?(:ref)

    return unpack_ref!(state, value, args) do |result|
      apply_arithmetic(result, value)
    end
  end

  def unpack_ref!(state, value, args)
    ref, attr = value[:ref].split(".").map(&:to_sym)
    container = @unpack_ref_container&.call(ref, args) || state[ref]
    raise "referenced unknown container #{ref.inspect}" if container.nil?
    if attr.nil? || !container.key?(attr)
      raise "referenced unknown attribute #{attr.inspect} on container #{ref.inspect} #{container.keys.inspect}"
    end
    return yield(container[attr])
  end

  def apply_arithmetic(input, value)
    return input if input.is_a?(Symbol) || !input.respond_to?(:dup)
    output =
      begin
        input.dup
      rescue TypeError
        input
      end
    if value.key?(:minus)
      # See: https://en.wikipedia.org/wiki/ISO_8601#Durations
      # Example: P30D for 30 days
      duration = ISO8601::Duration.new(value[:minus])
      output -= duration.to_seconds
    end
    return output
  end

  def next_step(plan, step_result)
    result = Marshal.load(Marshal.dump(step_result))

    plan.keys.select { |k| k.to_s =~ /^for_/ }.each do |key|
      _for, scope, ref = key.to_s.split("_", 3).map(&:to_sym)
      case scope
      when :this
        next if result[:content].nil?
        integrate!(plan[key], result) { yield(plan[key], result[:content]) }
      when :first
        content_ref = Marshal.load(Marshal.dump(result[:content]&.[](ref)))
        partition!(plan, key, content_ref, step_result) do |next_plan, content|
          next {content: nil} if content.nil?
          integrate!(next_plan, result) { yield(next_plan, content) }
        end
      when :each
        next if result[:content]&.[](ref).nil?
        result[:content][ref].map do |c|
          integrate!(plan[key], c) do
            next {content: plan[key][:default]} if plan[key][:default_if]&.call(c)
            next yield(plan[key], c)
          end
        end
      end
    end
    return result
  end

  def integrate!(plan, target)
    source = yield
    @merge_down_step&.call(target, source)
    attach = plan[:attach]
    source = source[:content]
    source = source&.[](attach[:from].to_sym) if attach.key?(:from)
    source = source.map { |k, v| ["#{attach[:prefix]}#{k}".to_sym, v] }.to_h if attach[:prefix]
    if attach[:merge]
      attach_merge!(target, source)
    elsif attach[:replace]
      attach_replace!(target, source)
    elsif attach[:to]
      attach_to!(attach, target, source)
    end
  end

  def attach_merge!(target, source)
    if target.key?(:content)
      target[:content] ||= {}
      target[:content].merge!(source || {})
    else
      target.merge!(source || {})
    end
  end

  def attach_replace!(target, source)
    if target.key?(:content)
      if source.nil?
        target[:content] = nil
      else
        target[:content] ||= {}
        target[:content].replace(source)
      end
    elsif source.nil?
      target.clear
    else
      target.replace(source)
    end
  end

  def attach_to!(attach, target, source)
    if target.key?(:content)
      target[:content] ||= {}
      target[:content].delete(attach[:from]) if attach[:from]
      target[:content][attach[:to].to_sym] = source
    else
      target.delete(attach[:from]) if attach[:from]
      target[attach[:to].to_sym] = source
    end
  end

  def partition!(plan, key, content_ref, step_result)
    content_ref, other_ref = plan[:partition].call(content_ref) if plan[:partition]
    if !content_ref.nil? && !content_ref.empty?
      yield(plan[key], content_ref.first)
    elsif !other_ref.nil? && !other_ref.empty? && plan[:fallback]
      yield(plan[:fallback], step_result)
    else
      yield(plan[key], nil)
    end
  end

  def validate_result!(step, step_result)
    return unless step.key?(:fail_if)
    step[:fail_if].each do |key, callback|
      path = key.to_s.split(".")
      value = path.reduce(step_result) { |a, k| a[k.to_sym] }
      next unless callback.to_proc.call(value)
      raise ValidationError, "#{key}: #{value.inspect} <- #{callback}"
    end
  end

  def skip_page_counts(result)
    metadata = result[:metadata]
    %w[delivered live from_cache].each do |suffix|
      field = "page_count_#{suffix}".to_sym
      next unless metadata[field]
      metadata[field] = 0
    end
    return # We need a nil, not an array
  end
end

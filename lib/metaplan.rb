# frozen_string_literal: true

module MetaPlan
  extend self

  VERSION = "0.1"

  def run(requester, source_obj, plan, state = {})
    validate_plan(plan, state)

    step = interpolate_step(source_obj, plan, state)
    step_result = run_step(step, requester, source_obj)
    validate_result!(step, step_result)

    if step[:set_page_count_delivered]
      metadata = step_result[:metadata]
      metadata[:page_count_delivered] = step[:set_page_count_delivered].to_i
    end

    return next_step(plan, step_result) do |next_plan, content|
      default = next_plan[:default_fn]&.call(requester, source_obj, next_plan, content)
      next default unless default.nil?
      next run(requester, source_obj, next_plan, state.merge(step[:as] => content))
    end
  end

  def with_plan_debugging(_scope, old_method, *args, &blk)
    return old_method.call(*args, &blk)
  rescue RuntimeError => error
    Utils.notify_error("run", args, error, true, false)
    raise error
  end

  def validate_plan(plan, state)
    required_fields = %i[as attach topic key value]
    required_fields.each do |field|
      next if plan.key?(field)
      raise "plan does not include required field #{field.inspect}"
    end
    raise "#{plan[:as]} already exists from a previous step" if state.key?(plan[:as].to_sym)
  end

  # Register the context, then interpret the plan according to registry
  def interpolate_step(source_obj, plan, state)
    step = plan.dup
    step[:as] = step[:as].to_sym
    step.replace(step.map { |k, v| [k, interpolate(source_obj, state, k, v)] }.to_h)
    step[:source] = source_obj.source
    step[:country] = source_obj.country
    if step[:max_pages] == :min_pages
      step[:max_pages] = [source_obj.max_pages, state[state.keys.first]&.[](:total_pages_count)]&.compact&.min
    end

    return step
  end

  # Interpolate the value with the registry
  # e.g. "current_product.id" may be interpolated to "product_1234"
  def interpolate(source_obj, state, key, value)
    return value if key.to_s =~ /^(as|attach|skip_page_count|for_.*)$/ || !value.is_a?(Hash) || !value.key?(:ref)

    container, attribute = container_do!(source_obj, state, value, check_attribute: true)
    result = container[attribute]
    return apply_arithmetic(result, value)
  end

  def container_do!(source_obj, state, value, check_attribute: false)
    ref, attr = value[:ref].split(".").map(&:to_sym)
    container = ref == :query ? source_obj.attributes : state[ref]
    raise "referenced unknown container #{ref.inspect}" if container.nil?
    if check_attribute && (attr.nil? || !container.key?(attr))
      raise "referenced unknown attribute #{attr.inspect} on container #{ref.inspect} #{container.keys.inspect}"
    end
    return container, attr
  end

  # rubocop:disable Metrics/BlockLength
  # rubocop:disable Metrics/MethodLength
  def next_step(plan, step_result)
    result = step_result.deep_dup

    skip_page_count = plan[:skip_page_count]
    plan.keys.select { |k| k.to_s =~ /^for_/ }.each do |key|
      _for, scope, ref = key.to_s.split("_", 3).map(&:to_sym)
      case scope
      when :this
        if result[:content].nil?
          skip_page_count = nil
          next
        end
        skip_page_count = skip_page_counts(result) if skip_page_count
        current_step_result = yield(plan[key], result[:content])
        add_effort!(result, current_step_result)
        integrate!(plan[key], result, current_step_result)
      when :first
        content_ref = result[:content]&.[](ref)&.deep_dup
        content_ref, other_ref = send(plan[:partition], content_ref) if plan[:partition]
        this_plan = plan[key]
        if content_ref.present?
          skip_page_count = skip_page_counts(result) if skip_page_count
          current_step_result = yield(plan[key], content_ref.first)
          add_effort!(result, current_step_result)
        elsif other_ref.present? && plan[:fallback]
          skip_page_count = skip_page_counts(result) if skip_page_count
          this_plan = plan[:fallback]
          current_step_result = yield(this_plan, step_result)
          add_effort!(result, current_step_result)
        else
          skip_page_count = nil
          current_step_result = {content: nil}
        end
        integrate!(this_plan, result, current_step_result)
      when :each
        if result[:content]&.[](ref).nil?
          skip_page_count = nil
          next
        end
        skip_page_count = skip_page_counts(result) if skip_page_count
        result[:content][ref].map do |c|
          if plan[key][:default_if]&.(c)
            current_step_result = {content: plan[key][:default]}
          else
            current_step_result = yield(plan[key], c)
            add_effort!(result, current_step_result)
          end

          integrate!(plan[key], c, current_step_result)
        end
      end
    end
    skip_page_counts(result) if skip_page_count # catch leaf nodes

    return result
  end
  # rubocop:enable Metrics/BlockLength
  # rubocop:enable Metrics/MethodLength

  def integrate!(plan, target, source)
    update_metadata_timestamp!(target, source)
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

  def update_metadata_timestamp!(target, source)
    target_date = target.dig(:metadata, :updated_at)
    source_date = source&.dig(:metadata, :updated_at)
    return if target_date.nil? || source_date.nil?
    return if Time.parse(source_date) <= Time.parse(target_date)
    target[:metadata][:updated_at] = source_date
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

  def run_step(step, requester, source_obj)
    source_obj.sub_topic(requester, **step)
  end

  def add_effort!(parent_result, step_result)
    parent_meta = parent_result[:metadata]
    step_meta = step_result[:metadata]
    %i[page_count_delivered page_count_live page_count_from_cache request_count].
      each { |k| parent_meta[k] += step_meta[k] || 0 }
  end

  def validate_result!(step, step_result)
    return unless step.key?(:fail_if)
    step[:fail_if].each do |key, callback|
      path = key.to_s.split(".")
      value = path.reduce(step_result) { |a, k| a[k.to_sym] }
      next unless callback.to_proc.call(value)
      raise Source::Requestable::ValidationError, "#{key}: #{value.inspect} <- #{callback}"
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

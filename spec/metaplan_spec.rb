# frozen_string_literal: true

require "minitest/autorun"
require "minitest/spec"
require "metaplan"

describe "MetaPlan" do
  after do
    MetaPlan.config(run_step: proc {})
  end

  describe "configuration options and their effects" do
    describe "required fields for a plan" do
      let(:config) do
        {
          run_step: ->(*_) { {content: nil} },
          required_fields: %i[as attach value]
        }
      end
      before { MetaPlan.config(**config) }

      it "raises a runtime error on missing field" do
        raised = false
        begin
          MetaPlan.run(plan: {as: :cake, attach: false})
        rescue RuntimeError
          raised = true
        end
        assert raised
      end

      it "works fine when all fields are there" do
        assert_equal(
          {content: nil},
          MetaPlan.run(plan: {as: :cake, attach: false, value: "moo"})
        )
      end
    end

    describe "step interpolation to add or change fields" do
      it "adds and modifies a step locally to be given to run_step" do
        MetaPlan.config(
          interpolate_step: proc do |step, _state|
            step[:value] += 1
            step[:value2] = "sweets"
          end,
          run_step: proc do |step|
            assert_equal(3, step[:value])
            assert_equal("sweets", step[:value2])
          end
        )
        plan = {as: :cake, attach: false, value: 2}
        MetaPlan.run(plan: plan)
        assert_equal(2, plan[:value])
      end
    end

    describe "unpacking from different source" do
      let(:source) { {value: 5} }
      let(:plan) { {as: :cake, attach: false, value: {ref: "source.value"}} }

      it "unpacks a value from a different ref container" do
        MetaPlan.config(
          unpack_ref_container: proc do |ref|
            source if ref == :source
          end,
          run_step: proc do |step|
            assert_equal(5, step[:value])
          end
        )
        MetaPlan.run(plan: plan)
      end

      it "makes given arguments available inside the proc" do
        MetaPlan.config(
          unpack_ref_container: proc do |_ref, args|
            assert_equal(%i[blu bar], args)
            next source
          end,
          run_step: proc {}
        )
        MetaPlan.run(plan: plan, args: %i[blu bar])
      end
    end

    describe "post processing a step result" do
      let(:result) { {content: {}} }
      let(:plan) do
        {as: :cake, attach: false, for_this_1: {as: :topping, attach: {to: :t}}}
      end

      it "makes step and result available inside the proc" do
        MetaPlan.config(
          post_step: proc do |step, step_result|
            if step[:as] == :cake
              assert_equal(plan, step)
            else
              assert_equal(plan[:for_this_1], step)
            end
            assert_equal(result, step_result)
          end,
          run_step: proc { result }
        )
        MetaPlan.run(plan: plan)
      end

      it "modifies the result" do
        MetaPlan.config(
          post_step: proc do |step, step_result|
            step_result[:content] = {step[:as] => "m"}
          end,
          run_step: proc { result }
        )
        assert_equal(
          {content: {cake: "m", t: {topping: "m"}}},
          MetaPlan.run(plan: plan)
        )
      end
    end

    describe "merging down a step result" do
      let(:plan) do
        {as: :cake, attach: false, for_this_1: {as: :topping, attach: {to: :t}}}
      end

      it "makes result and step result available inside the proc" do
        MetaPlan.config(
          merge_down_step: proc do |result, content, step_result|
            assert_equal({content: {}}, result)
            assert_equal({content: {}}, content)
            assert_equal({content: {}}, step_result)
          end,
          run_step: proc { {content: {}} }
        )
        MetaPlan.run(plan: plan)
      end
    end
  end

  describe "single level plan" do
    let(:config) { {run_step: ->(*_) { {content: nil} }} }
    let(:plan) { {as: :cake, attach: false} }

    it "returns the run_step result" do
      MetaPlan.config(**config)
      assert_equal({content: nil}, MetaPlan.run(plan: plan))
    end

    it "makes the current step and arguments available in run_step" do
      MetaPlan.config(
        run_step: proc do |step, args|
          assert_equal(plan, step)
          assert_equal(%i[blu bar], args)
          next {content: nil}
        end
      )
      MetaPlan.run(plan: plan, args: %i[blu bar])
    end
  end

  describe "multi level plan" do
    it "can access previous step data" do
      counter = 0
      MetaPlan.config(
        run_step: proc do |step|
          counter += 1
          {content: {val: step[:value], c: counter}}
        end
      )
      result = MetaPlan.run(
        plan: {
          as: :cake,
          attach: false,
          for_this_1: {
            as: :topping,
            attach: {to: :t},
            value: {ref: "cake.c"}
          }
        }
      )
      assert_equal(2, counter)
      assert_equal({content: {val: nil, c: 1, t: {val: 1, c: 2}}}, result)
    end

    describe "attaching sub results" do
      it "merges into previous result" do
        counter = 0
        MetaPlan.config(
          run_step: proc do |_step|
            counter += 1
            {content: {counter.to_s.to_sym => counter, c: counter}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            for_this_1: {
              as: :topping,
              attach: {merge: true}
            }
          }
        )
        assert_equal(2, counter)
        assert_equal({content: {"1": 1, "2": 2, c: 2}}, result)
      end

      it "replaces previous result" do
        counter = 0
        MetaPlan.config(
          run_step: proc do |_step|
            counter += 1
            {content: {counter.to_s.to_sym => counter, c: counter}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            for_this_1: {
              as: :topping,
              attach: {replace: true}
            }
          }
        )
        assert_equal(2, counter)
        assert_equal({content: {"2": 2, c: 2}}, result)
      end

      it "adds a prefix to the result" do
        counter = 0
        MetaPlan.config(
          run_step: proc do |_step|
            counter += 1
            {content: {counter.to_s.to_sym => counter, c: counter}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            for_this_1: {
              as: :topping,
              attach: {replace: true, prefix: "b_"}
            }
          }
        )
        assert_equal(2, counter)
        assert_equal({content: {"b_2": 2, b_c: 2}}, result)
      end

      it "attaches whole result to a key" do
        counter = 0
        MetaPlan.config(
          run_step: proc do |_step|
            counter += 1
            {content: {c: counter}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            for_this_1: {
              as: :topping,
              attach: {to: :s}
            }
          }
        )
        assert_equal(2, counter)
        assert_equal({content: {c: 1, s: {c: 2}}}, result)
      end

      it "attaches from a key to a new key" do
        counter = 0
        MetaPlan.config(
          run_step: proc do |_step|
            counter += 1
            {content: {counter.to_s.to_sym => counter}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            for_this_1: {
              as: :topping,
              attach: {from: :"2", to: :s}
            }
          }
        )
        assert_equal(2, counter)
        assert_equal({content: {"1": 1, s: 2}}, result)
      end

      it "attaching from key a to key b removes a from target result" do
        counter = 0
        MetaPlan.config(
          run_step: proc do |_step|
            counter += 1
            {content: {c: counter}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            for_this_1: {
              as: :topping,
              attach: {from: :c, to: :s}
            }
          }
        )
        assert_equal(2, counter)
        assert_equal({content: {s: 2}}, result)
      end
    end

    describe "nesting plans" do
      let(:plan) do
        {
          as: :cake,
          attach: false,
          for_this_1: {
            as: :topping,
            attach: {to: :t},
            val: {ref: "cake.s"}
          },
          for_this_2: {
            as: :chocolate,
            attach: {to: :c}
          }
        }
      end

      describe "for_this" do
        it "makes the previous result hash directly available" do
          MetaPlan.config(run_step: proc { |s| {content: {s: s[:as], v: s[:val]}} })
          assert_equal(
            {
              content: {
                s: :cake, v: nil,
                t: {s: :topping, v: :cake},
                c: {s: :chocolate, v: nil}
              }
            },
            MetaPlan.run(plan: plan)
          )
        end

        it "handles empty content of the outer step" do
          MetaPlan.config(run_step: proc { |_s| {content: nil} })
          assert_equal({content: nil}, MetaPlan.run(plan: plan))
        end
      end

      describe "for_first" do
        let(:plan) do
          {
            as: :cake,
            attach: false,
            for_first_list: {
              as: :topping,
              attach: {from: :list, to: :t},
              val: {ref: "cake.s"}
            }
          }
        end

        it "makes the first result available" do
          MetaPlan.config(
            run_step: proc do |step|
              {content: {list: [{s: step[:as], v: step[:val]}]}}
            end
          )
          assert_equal(
            {content: {t: [{s: :topping, v: :cake}]}},
            MetaPlan.run(plan: plan)
          )
        end

        it "handles empty arrays on the outer step" do
          MetaPlan.config(
            run_step: proc do |_step|
              {content: {list: []}}
            end
          )
          assert_equal({content: {list: []}}, MetaPlan.run(plan: plan))
        end

        it "handles nil result on the outer step" do
          MetaPlan.config(
            run_step: proc do |_step|
              {content: nil}
            end
          )
          assert_equal({content: nil}, MetaPlan.run(plan: plan))
        end
      end

      describe "for_each" do
        let(:plan) do
          {
            as: :cake,
            attach: false,
            for_each_list: {
              as: :toppings,
              attach: {merge: true},
              val: {ref: "cake.s"}
            }
          }
        end

        it "loops all results and makes the previous step available" do
          MetaPlan.config(
            run_step: proc do |step|
              if step[:attach]
                {content: {s: step[:as], v: step[:val]}}
              else
                {content: {list: [{s: step[:as]}]}}
              end
            end
          )
          assert_equal(
            {content: {list: [{s: :toppings, v: :cake}]}},
            MetaPlan.run(plan: plan)
          )
        end

        it "handles empty result on the outer step" do
          MetaPlan.config(run_step: proc { |_s| {content: {list: []}} })
          assert_equal({content: {list: []}}, MetaPlan.run(plan: plan))
        end

        it "handles nil result on the outer step" do
          MetaPlan.config(run_step: proc { |_s| {content: nil} })
          assert_equal({content: nil}, MetaPlan.run(plan: plan))
        end
      end
    end

    describe "partitioning with a fallback plan in for_first" do
      it "uses an alternative plan with the given step result" do
        MetaPlan.config(
          run_step: proc do |step|
            {content: {step: step[:as], list: [{a: 1}, {a: 2}]}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            partition: ->(l) { l.partition { |h| h[:a] == 3 } },
            fallback: {
              as: :whip,
              attach: {replace: true}
            },
            for_first_list: {
              as: :topping,
              attach: {merge: true}
            }
          }
        )
        assert_equal({content: {step: :whip, list: [{a: 1}, {a: 2}]}}, result)
      end

      it "uses the regular plan with the given step result" do
        MetaPlan.config(
          run_step: proc do |step|
            {content: {step: step[:as], list: [{a: 1}, {a: 2}]}}
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            partition: ->(l) { l.partition { |h| h[:a] == 1 } },
            fallback: {
              as: :whip,
              attach: {replace: true}
            },
            for_first_list: {
              as: :topping,
              attach: {replace: true}
            }
          }
        )
        assert_equal({content: {step: :topping, list: [{a: 1}, {a: 2}]}}, result)
      end
    end

    describe "default values in for_each" do
      it "uses a default value when callback is true" do
        MetaPlan.config(
          run_step: proc do |step|
            if step[:attach]
              {content: {i: step[:val]}}
            else
              {content: {list: [{i: 1}, {i: 2}]}}
            end
          end
        )
        result = MetaPlan.run(
          plan: {
            as: :cake,
            attach: false,
            for_each_list: {
              as: :toppings,
              attach: {merge: true},
              val: {ref: "cake.i"},
              default_if: ->(v) { v[:i] == 2 },
              default: {i: 3}
            }
          }
        )
        assert_equal({content: {list: [{i: 1}, {i: 3}]}}, result)
      end
    end

    describe "validating result with fail_if" do
      it "raises validation error when fail_if to_proc is true" do
        raised = false
        MetaPlan.config(
          run_step: proc do |_step|
            {content: {list: [{i: 1}, {i: 2}]}}
          end
        )
        begin
          MetaPlan.run(
            plan: {
              as: :cake,
              attach: false,
              fail_if: {"content.list": :any?}
            }
          )
        rescue MetaPlan::ValidationError
          raised = true
        end
        assert raised
      end

      it "raises no validation error when fail_if to_proc is false" do
        raised = false
        MetaPlan.config(
          run_step: proc do |_step|
            {content: {list: [{i: 1}, {i: 2}]}}
          end
        )
        begin
          MetaPlan.run(
            plan: {
              as: :cake,
              attach: false,
              fail_if: {"content.list": ->(v) { v.any? { |e| e[:i] == 3 } }}
            }
          )
        rescue MetaPlan::ValidationError
          raised = true
        end
        refute raised
      end
    end
  end
end

require 'spec_helper'

describe BD::DeploymentPlan::InstancePlanner do
  subject(:instance_planner) { BD::DeploymentPlan::InstancePlanner.new(logger, instance_repo, skip_drain_decider, options) }
  let(:options) { {} }
  let(:skip_drain_decider) { BD::DeploymentPlan::AlwaysSkipDrain.new }
  let(:logger) { instance_double(Logger, debug: nil, info: nil) }
  let(:instance_repo) { BD::DeploymentPlan::InstanceRepository.new(logger) }
  let(:deployment) { instance_double(BD::DeploymentPlan::Planner) }
  let(:az) do
    BD::DeploymentPlan::AvailabilityZone.new(
      'foo-az',
      'cloud_properties' => {}
    )
  end
  let(:undesired_az) do
    BD::DeploymentPlan::AvailabilityZone.new(
      'old-az',
      'cloud_properties' => {}
    )
  end
  let(:job) { instance_double(BD::DeploymentPlan::Job, name: 'foo-job', availability_zones: [az], migrated_from: []) }
  let(:desired_instance) { BD::DeploymentPlan::DesiredInstance.new(job, 'started', deployment) }
  let(:tracer_instance) { instance_double(BD::DeploymentPlan::Instance, update_description: nil) }

  describe '#plan_job_instances' do
    before do
      allow(job).to receive(:networks).and_return([])
    end
    
    context 'when instance should skip running drain script' do
      let(:skip_drain_decider) { BD::DeploymentPlan::SkipDrain.new('*') }

      it 'should set "skip_drain" on the instance plan' do
        existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, availability_zone: az.name)
        existing_instance_state = {'foo' => 'bar'}
        states_by_existing_instance = {existing_instance_model => existing_instance_state}

        instance_plans = instance_planner.plan_job_instances(job, [desired_instance], [existing_instance_model], states_by_existing_instance)
        expect(instance_plans.select(&:skip_drain).count).to eq(instance_plans.count)
      end
    end

    context 'when deployment is being recreated' do
      let(:options) { {'recreate' => true} }

      it 'should return instance plans with "recreate" option set on them' do
        existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, availability_zone: az.name)
        existing_instance_state = {'foo' => 'bar'}
        states_by_existing_instance = {existing_instance_model => existing_instance_state}

        instance_plans = instance_planner.plan_job_instances(job, [desired_instance], [existing_instance_model], states_by_existing_instance)

        expect(instance_plans.select(&:recreate_deployment).count).to eq(instance_plans.count)
      end
    end

    context 'when job has no az' do
      let(:job) do
        instance_double(BD::DeploymentPlan::Job, name: 'foo-job', availability_zones: [])
      end

      it 'creates instance plans for new instances with no az' do
        existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0)
        existing_instance_state = {'foo' => 'bar'}
        states_by_existing_instance = {existing_instance_model => existing_instance_state}

        allow(instance_repo).to receive(:fetch_existing).with(desired_instance, existing_instance_model, existing_instance_state) { tracer_instance }

        instance_plans = instance_planner.plan_job_instances(job, [desired_instance], [existing_instance_model], states_by_existing_instance)

        expect(instance_plans.count).to eq(1)
        existing_instance_plan = instance_plans.first

        expected_desired_instance = BD::DeploymentPlan::DesiredInstance.new(
          job,
          'started',
          deployment,
          nil,
          0
        )
        expect(existing_instance_plan.new?).to eq(false)
        expect(existing_instance_plan.obsolete?).to eq(false)

        expect(existing_instance_plan.desired_instance.job).to eq(expected_desired_instance.job)
        expect(existing_instance_plan.desired_instance.state).to eq(expected_desired_instance.state)
        expect(existing_instance_plan.desired_instance.deployment).to eq(expected_desired_instance.deployment)
        expect(existing_instance_plan.desired_instance.az).to eq(expected_desired_instance.az)
        expect(existing_instance_plan.desired_instance.bootstrap?).to eq(true)

        expect(existing_instance_plan.instance).to eq(tracer_instance)
        expect(existing_instance_plan.existing_instance).to eq(existing_instance_model)
      end
    end

    describe 'moving an instance to a different az' do
      it "should not attempt to reuse the existing instance's index" do
        existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, availability_zone: undesired_az.name)
        another_existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 1, availability_zone: undesired_az.name)
        existing_instances = [existing_instance_model, another_existing_instance_model]
        states_by_existing_instance = {}

        desired_instances = [desired_instance]
        expected_new_instance_index = 2
        allow(instance_repo).to receive(:create).with(desired_instances[0], expected_new_instance_index) { instance_double(BD::DeploymentPlan::Instance) }

        instance_plans = instance_planner.plan_job_instances(job, desired_instances, existing_instances, states_by_existing_instance)

        expect(instance_plans.count).to eq(3)
        obsolete_instance_plan = instance_plans[1]
        another_obsolete_instance_plan = instance_plans[2]

        expect(obsolete_instance_plan.new?).to eq(false)
        expect(obsolete_instance_plan.obsolete?).to eq(true)
        expect(obsolete_instance_plan.existing_instance).to eq(existing_instance_model)

        expect(another_obsolete_instance_plan.new?).to eq(false)
        expect(another_obsolete_instance_plan.obsolete?).to eq(true)
        expect(another_obsolete_instance_plan.existing_instance).to eq(another_existing_instance_model)

        new_instance_plan = instance_plans.first
        expect(new_instance_plan.new?).to eq(true)
        expect(new_instance_plan.obsolete?).to eq(false)
      end
    end

    it 'creates instance plans for existing instances' do
      existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, availability_zone: az.name)
      existing_instance_state = {'foo' => 'bar'}
      states_by_existing_instance = {existing_instance_model => existing_instance_state}

      allow(instance_repo).to receive(:fetch_existing).with(desired_instance, existing_instance_model, existing_instance_state) { tracer_instance }

      instance_plans = instance_planner.plan_job_instances(job, [desired_instance], [existing_instance_model], states_by_existing_instance)

      expect(instance_plans.count).to eq(1)
      existing_instance_plan = instance_plans.first

      expected_desired_instance = BD::DeploymentPlan::DesiredInstance.new(
        job,
        'started',
        deployment,
        az,
        0
      )
      expect(existing_instance_plan.new?).to eq(false)
      expect(existing_instance_plan.obsolete?).to eq(false)

      expect(existing_instance_plan.desired_instance.job).to eq(expected_desired_instance.job)
      expect(existing_instance_plan.desired_instance.state).to eq(expected_desired_instance.state)
      expect(existing_instance_plan.desired_instance.deployment).to eq(expected_desired_instance.deployment)
      expect(existing_instance_plan.desired_instance.az).to eq(expected_desired_instance.az)
      expect(existing_instance_plan.desired_instance.bootstrap?).to eq(true)

      expect(existing_instance_plan.instance).to eq(tracer_instance)
      expect(existing_instance_plan.existing_instance).to eq(existing_instance_model)
    end

    it 'updates descriptions for existing instances' do
      existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, availability_zone: az.name)
      allow(instance_repo).to receive(:fetch_existing).with(desired_instance, existing_instance_model, {}) { tracer_instance }
      expect(tracer_instance).to receive(:update_description)

      instance_planner.plan_job_instances(job, [desired_instance], [existing_instance_model], {existing_instance_model => {}})
    end

    it 'creates instance plans for new instances' do
      existing_instances = []
      states_by_existing_instance = {}

      allow(instance_repo).to receive(:create).with(desired_instance, 0) { tracer_instance }

      instance_plans = instance_planner.plan_job_instances(job, [desired_instance], existing_instances, states_by_existing_instance)

      expect(instance_plans.count).to eq(1)
      new_instance_plan = instance_plans.first

      expect(new_instance_plan.new?).to eq(true)
      expect(new_instance_plan.obsolete?).to eq(false)
      expect(new_instance_plan.desired_instance).to eq(desired_instance)
      expect(new_instance_plan.instance).to eq(tracer_instance)
      expect(new_instance_plan.existing_instance).to be_nil
      expect(new_instance_plan).to be_new
    end

    it 'creates instance plans for new, existing and obsolete instances' do
      out_of_typical_range_index = 77
      auto_picked_index = 0

      desired_existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: out_of_typical_range_index, availability_zone: az.name)
      desired_existing_instance_state = {'bar' => 'baz'}

      desired_instances = [desired_instance, BD::DeploymentPlan::DesiredInstance.new(job, nil, deployment, az, out_of_typical_range_index)]

      undesired_existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: auto_picked_index, availability_zone: undesired_az.name)
      undesired_existing_instance_state = {'foo' => 'bar'}

      states_by_existing_instance = {
        undesired_existing_instance_model => undesired_existing_instance_state,
        desired_existing_instance_model => desired_existing_instance_state,
      }

      existing_instances = [undesired_existing_instance_model, desired_existing_instance_model]
      allow(instance_repo).to receive(:fetch_existing).with(desired_instance, desired_existing_instance_model, desired_existing_instance_state) do
        instance_double(BD::DeploymentPlan::Instance, index: out_of_typical_range_index, update_description: nil)
      end

      allow(instance_repo).to receive(:create).with(desired_instances[1], 1) { instance_double(BD::DeploymentPlan::Instance) }

      instance_plans = instance_planner.plan_job_instances(job, desired_instances, existing_instances, states_by_existing_instance)
      expect(instance_plans.count).to eq(3)

      existing_instance_plan = instance_plans.first
      expect(existing_instance_plan.new?).to eq(false)
      expect(existing_instance_plan.obsolete?).to eq(false)

      new_instance_plan = instance_plans[1]
      expect(new_instance_plan.new?).to eq(true)
      expect(new_instance_plan.obsolete?).to eq(false)

      obsolete_instance_plan = instance_plans[2]
      expect(obsolete_instance_plan.new?).to eq(false)
      expect(obsolete_instance_plan.obsolete?).to eq(true)
      expect(obsolete_instance_plan.desired_instance).to be_nil
      expect(obsolete_instance_plan.existing_instance).to eq(undesired_existing_instance_model)
      expect(obsolete_instance_plan.instance).to be_nil
    end

    context 'resolving bootstrap nodes' do
      context 'when existing instance is marked as bootstrap' do
        it 'keeps bootstrap node' do
          existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, bootstrap: true, availability_zone: az.name)
          existing_instance_state = {'foo' => 'bar'}
          states_by_existing_instance = {existing_instance_model => existing_instance_state}

          existing_tracer_instance = instance_double(BD::DeploymentPlan::Instance, bootstrap?: true, update_description: nil)
          allow(instance_repo).to receive(:fetch_existing).with(desired_instance, existing_instance_model, existing_instance_state) { existing_tracer_instance }

          instance_plans = instance_planner.plan_job_instances(job, [desired_instance], [existing_instance_model], states_by_existing_instance)

          expect(instance_plans.count).to eq(1)
          existing_instance_plan = instance_plans.first

          expect(existing_instance_plan.new?).to be_falsey
          expect(existing_instance_plan.obsolete?).to be_falsey
          expect(existing_instance_plan.instance).to eq(existing_tracer_instance)
          expect(existing_instance_plan.desired_instance.bootstrap?).to be_truthy
        end
      end

      context 'when obsolete instance is marked as bootstrap' do
        it 'picks the lowest indexed instance as new bootstrap instance' do
          existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, bootstrap: true, availability_zone: undesired_az.name)
          another_existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 1, availability_zone: az.name)
          another_desired_instance = BD::DeploymentPlan::DesiredInstance.new(job, nil, deployment, az, 1)
          existing_instance_state = {'foo' => 'bar'}
          states_by_existing_instance = {existing_instance_model => existing_instance_state, another_existing_instance_model => existing_instance_state}

          tracer_instance = instance_double(BD::DeploymentPlan::Instance)
          existing_tracer_instance = instance_double(BD::DeploymentPlan::Instance, index: 1, bootstrap?: true, update_description: nil)
          allow(instance_repo).to receive(:fetch_existing).with(another_desired_instance, another_existing_instance_model, existing_instance_state) { existing_tracer_instance }
          allow(instance_repo).to receive(:create).with(desired_instance, 2) { tracer_instance }

          instance_plans = instance_planner.plan_job_instances(job, [another_desired_instance, desired_instance], [existing_instance_model, another_existing_instance_model], states_by_existing_instance)

          expect(instance_plans.count).to eq(3)
          desired_existing_instance_plan = instance_plans.first
          desired_new_instance_plan = instance_plans[1]
          obsolete_instance_plan = instance_plans.last

          expect(obsolete_instance_plan.obsolete?).to be_truthy
          expect(desired_existing_instance_plan.instance).to eq(existing_tracer_instance)
          expect(desired_existing_instance_plan.desired_instance.bootstrap?).to be_truthy
          expect(desired_new_instance_plan.desired_instance.bootstrap?).to be_falsey
        end
      end

      context 'when several existing instances are marked as bootstrap' do
        it 'picks the lowest indexed instance as new bootstrap instance' do
          existing_instance_model_1 = BD::Models::Instance.make(job: 'foo-job-z1', index: 0, bootstrap: true, availability_zone: az.name)
          desired_instance_1 = BD::DeploymentPlan::DesiredInstance.new(job, nil, deployment, az, 0)
          existing_instance_model_2 = BD::Models::Instance.make(job: 'foo-job-z2', index: 0, bootstrap: true, availability_zone: az.name)
          desired_instance_2 = BD::DeploymentPlan::DesiredInstance.new(job, nil, deployment, az, 1)
          existing_instance_state = {}
          states_by_existing_instance = {existing_instance_model_1 => existing_instance_state, existing_instance_model_2 => existing_instance_state}

          existing_tracer_instance_1 = instance_double(BD::DeploymentPlan::Instance, index: 0, update_description: nil)
          existing_tracer_instance_2 = instance_double(BD::DeploymentPlan::Instance, index: 1, update_description: nil)
          allow(instance_repo).to receive(:fetch_existing).with(desired_instance_1, existing_instance_model_1, existing_instance_state) { existing_tracer_instance_1 }
          allow(instance_repo).to receive(:fetch_existing).with(desired_instance_2, existing_instance_model_2, existing_instance_state) { existing_tracer_instance_2 }

          instance_plans = instance_planner.plan_job_instances(job, [desired_instance_1, desired_instance_2], [existing_instance_model_1, existing_instance_model_2], states_by_existing_instance)

          expect(instance_plans.count).to eq(2)
          bootstrap_instance_plans = instance_plans.select { |ip| ip.desired_instance.bootstrap? }
          expect(bootstrap_instance_plans.size).to eq(1)
          expect(bootstrap_instance_plans.first.desired_instance.index).to eq(0)
        end
      end

      context 'when there are no bootstrap instances' do
        it 'assigns the instance with the lowest index as bootstrap instance' do
          existing_instances = []
          states_by_existing_instance = {}
          another_desired_instance = BD::DeploymentPlan::DesiredInstance.new(job, nil, deployment)

          tracer_instance = instance_double(BD::DeploymentPlan::Instance, bootstrap?: true)
          allow(instance_repo).to receive(:create).with(desired_instance, 0) { tracer_instance }

          another_tracer_instance = instance_double(BD::DeploymentPlan::Instance)
          allow(instance_repo).to receive(:create).with(another_desired_instance, 1) { another_tracer_instance }

          instance_plans = instance_planner.plan_job_instances(job, [desired_instance, another_desired_instance], existing_instances, states_by_existing_instance)

          expect(instance_plans.count).to eq(2)
          new_instance_plan = instance_plans.first

          expect(new_instance_plan.new?).to be_truthy
          expect(new_instance_plan.desired_instance.bootstrap?).to be_truthy
          expect(new_instance_plan.instance).to eq(tracer_instance)
          expect(new_instance_plan.existing_instance).to be_nil
        end
      end

      context 'when all instances are obsolete' do
        it 'should not mark any instance as bootstrap instance' do
          existing_instance_model = BD::Models::Instance.make(job: 'foo-job', index: 0, bootstrap: true, availability_zone: undesired_az.name)
          existing_instance_state = {'foo' => 'bar'}
          states_by_existing_instance = {existing_instance_model => existing_instance_state}

          obsolete_instance = instance_double(BD::DeploymentPlan::Instance, update_description: nil)
          allow(instance_repo).to receive(:fetch_obsolete).with(existing_instance_model) { obsolete_instance }

          instance_plans = instance_planner.plan_job_instances(job, [], [existing_instance_model], states_by_existing_instance)

          expect(instance_plans.count).to eq(1)
          obsolete_instance_plan = instance_plans.first

          expect(obsolete_instance_plan.obsolete?).to be_truthy
        end
      end
    end
  end

  describe '#plan_obsolete_jobs' do
    it 'returns instance plans for each job' do
      existing_instance_thats_desired = BD::Models::Instance.make(job: 'foo-job', index: 0)
      existing_instance_thats_obsolete = BD::Models::Instance.make(job: 'bar-job', index: 1)

      existing_instances = [existing_instance_thats_desired, existing_instance_thats_obsolete]
      instance_plans = instance_planner.plan_obsolete_jobs([job], existing_instances)

      expect(instance_plans.count).to eq(1)

      obsolete_instance_plan = instance_plans.first
      expect(obsolete_instance_plan.instance).to be_nil
      expect(obsolete_instance_plan.desired_instance).to be_nil
      expect(obsolete_instance_plan.existing_instance).to eq(existing_instance_thats_obsolete)
      expect(obsolete_instance_plan).to be_obsolete
    end
  end
end
# Copyright (c) 2009-2012 VMware, Inc.

require File.expand_path("../../spec_helper", __FILE__)

describe Bosh::Director::PackageCompiler do

  # TODO: add tests for build numbers and some error conditions

  before(:each) do
    @cloud = mock(:cpi)
    BD::Config.stub!(:cloud).and_return(@cloud)

    @blobstore = mock(:blobstore)
    BD::Config.stub!(:blobstore).and_return(@blobstore)

    @director_job = mock(BD::Jobs::BaseJob)
    BD::Config.stub!(:current_job).and_return(@director_job)
    @director_job.stub!(:task_cancelled?).and_return(false)

    @deployment = BD::Models::Deployment.make(:name => "mycloud")
    @config = mock(BD::DeploymentPlan::CompilationConfig)
    @plan = mock(BD::DeploymentPlan, :compilation => @config,
                 :model => @deployment, :name => "mycloud")
    @network = mock(BD::DeploymentPlan::Network, :name => "default")

    @n_workers = 3
    @config.stub!(:deployment => @plan, :network => @network,
                  :env => {}, :cloud_properties => {}, :workers => @n_workers,
                  :reuse_compilation_vms => false)

    BD::Config.stub(:use_global_blobstore?).and_return(false)
    @all_packages = []
  end

  def make(plan)
    BD::PackageCompiler.new(plan)
  end

  def make_package(name, deps = [], version = "0.1-dev")
    package = BD::Models::Package.make(:name => name, :version => version)
    package.dependency_set = deps
    package.save
    @all_packages << package
    package
  end

  def make_compiled(package, stemcell, sha1 = "deadbeef",
                    blobstore_id = "deadcafe")
    # A little bit of prep to satisfy dependency keys
    # TODO: make less manual to set up
    deps = package.dependency_set.map do |dep_name|
      BD::Models::Package.find(:name => dep_name)
    end
    dep_key = BD::Models::CompiledPackage.generate_dependency_key(deps)

    BD::Models::CompiledPackage.make(:package => package,
                                     :dependency_key => dep_key,
                                     :stemcell => stemcell,
                                     :build => 1,
                                     :sha1 => sha1,
                                     :blobstore_id => blobstore_id)
  end

  def prepare_samples
    @release = mock(BD::DeploymentPlan::Release, :name => "cf-release",
                    :model => BD::Models::ReleaseVersion.make)
    @stemcell_a = mock(BD::DeploymentPlan::Stemcell,
                       :model => BD::Models::Stemcell.make)
    @stemcell_b = mock(BD::DeploymentPlan::Stemcell,
                       :model => BD::Models::Stemcell.make)

    @p_common = make_package("common")
    @p_syslog = make_package("p_syslog")
    @p_dea = make_package("dea", %w(ruby common))
    @p_ruby = make_package("ruby", %w(common))
    @p_warden = make_package("warden", %w(common))
    @p_nginx = make_package("nginx", %w(common))
    @p_router = make_package("p_router", %w(ruby common))

    rp_large = mock(BD::DeploymentPlan::ResourcePool,
                    :name => "large", :stemcell => @stemcell_a)

    rp_small = mock(BD::DeploymentPlan::ResourcePool,
                    :name => "small", :stemcell => @stemcell_b)

    @t_dea = mock(BD::DeploymentPlan::Template,
                 :package_models => [@p_dea, @p_nginx, @p_syslog])

    @t_warden = mock(BD::DeploymentPlan::Template,
                    :package_models => [@p_warden])

    @t_nginx = mock(BD::DeploymentPlan::Template,
                   :package_models => [@p_nginx])

    @t_router = mock(BD::DeploymentPlan::Template,
                    :package_models => [@p_router])

    @j_dea = mock(BD::DeploymentPlan::Job,
                  :name => "dea",
                  :release => @release,
                  :templates => [@t_dea, @t_warden],
                  :resource_pool => rp_large)
    @j_router = mock(BD::DeploymentPlan::Job,
                     :name => "router",
                     :release => @release,
                     :templates => [@t_nginx, @t_router, @t_warden],
                     :resource_pool => rp_small)

    @package_set_a = [
      @p_dea, @p_nginx, @p_syslog,
      @p_warden, @p_common, @p_ruby
    ]

    @package_set_b = [
      @p_nginx, @p_common, @p_router,
      @p_warden, @p_ruby
    ]

    # Dependencies lookup expected!
    @release.should_receive(:get_package_model_by_name).
      with("ruby").at_least(1).times.and_return(@p_ruby)
    @release.should_receive(:get_package_model_by_name).
      with("common").at_least(1).times.and_return(@p_common)
  end

  it "doesn't do anything if there are no packages to compile" do
    prepare_samples

    @plan.stub(:jobs).and_return([@j_dea, @j_router])

    @package_set_a.each do |package|
      cp1 = make_compiled(package, @stemcell_a.model)
      @j_dea.should_receive(:use_compiled_package).with(cp1)
    end

    @package_set_b.each do |package|
      cp2 = make_compiled(package, @stemcell_b.model)
      @j_router.should_receive(:use_compiled_package).with(cp2)
    end

    compiler = make(@plan)
    compiler.compile
    # For @stemcell_a we need to compile:
    # [p_dea, p_nginx, p_syslog, p_warden, p_common, p_ruby] = 6
    # For @stemcell_b:
    # [p_nginx, p_common, p_router, p_ruby, p_warden] = 5
    compiler.compile_tasks_count.should == 6 + 5
    # But they are already compiled!
    compiler.compilations_performed.should == 0
  end

  it "compiles all packages" do
    prepare_samples

    @plan.stub(:jobs).and_return([@j_dea, @j_router])
    compiler = make(@plan)

    @network.should_receive(:reserve).at_least(@n_workers).times do |reservation|
      reservation.should be_an_instance_of(BD::NetworkReservation)
      reservation.reserved = true
    end

    @network.should_receive(:network_settings).
      exactly(11).times.and_return("network settings")

    net = {"default" => "network settings"}
    vm_cids = (0..10).map { |i| "vm-cid-#{i}" }
    agents = (0..10).map { mock(BD::AgentClient) }

    @cloud.should_receive(:create_vm).exactly(6).times.
      with(instance_of(String), @stemcell_a.model.cid, {}, net, nil, {}).
      and_return(*vm_cids[0..5])

    @cloud.should_receive(:create_vm).exactly(5).times.
      with(instance_of(String), @stemcell_b.model.cid, {}, net, nil, {}).
      and_return(*vm_cids[6..10])

    BD::AgentClient.should_receive(:new).exactly(11).times.and_return(*agents)

    agents.each do |agent|
      initial_state = {
        "deployment" => "mycloud",
        "resource_pool" => "package_compiler",
        "networks" => net
      }

      agent.should_receive(:wait_until_ready)
      agent.should_receive(:apply).with(initial_state)
      agent.should_receive(:compile_package) do |*args|
        name = args[2]
        dot = args[3].rindex(".")
        version, build = args[3][0..dot-1], args[3][dot+1..-1]

        package = BD::Models::Package.find(:name => name, :version => version)
        args[0].should == package.blobstore_id
        args[1].should == package.sha1

        args[4].should be_a(Hash)

        {
          "result" => {
            "sha1" => "compiled #{package.id}",
            "blobstore_id" => "blob #{package.id}"
          }
        }
      end
    end

    @package_set_a.each do |package|
      compiler.should_receive(:with_compile_lock).
          with(package.id, @stemcell_a.model.id).and_yield
    end

    @package_set_b.each do |package|
      compiler.should_receive(:with_compile_lock).
          with(package.id, @stemcell_b.model.id).and_yield
    end

    @j_dea.should_receive(:use_compiled_package).exactly(6).times
    @j_router.should_receive(:use_compiled_package).exactly(5).times

    vm_cids.each do |vm_cid|
      @cloud.should_receive(:delete_vm).with(vm_cid)
    end

    @network.should_receive(:release).at_least(@n_workers).times
    @director_job.should_receive(:task_checkpoint).once

    compiler.compile
    compiler.compilations_performed.should == 11

    @package_set_a.each do |package|
      package.compiled_packages.size.should >= 1
    end

    @package_set_b.each do |package|
      package.compiled_packages.size.should >= 1
    end
  end

  it "reuses compilation VMs if this option is set" do
    # TODO add fair stemcell scheduling for compilation reuse:
    # right now it seems there's a race and same stemcell can hijack
    # all num_workers VMs, thus we test with one stemcell
    # NOTE: test compilations are so fast that we're not guaranteed that
    # all 3 VMs will actually be created, hence using fuzzy expectations
    prepare_samples
    @plan.stub(:jobs).and_return([@j_dea])

    @config.stub!(:reuse_compilation_vms => true)

    @network.should_receive(:reserve).at_most(@n_workers).times do |reservation|
      reservation.should be_an_instance_of(BD::NetworkReservation)
      reservation.reserved = true
    end

    @network.should_receive(:network_settings).
      at_most(3).times.and_return("network settings")

    net = {"default" => "network settings"}
    vm_cids = (0..2).map { |i| "vm-cid-#{i}" }
    agents = (0..2).map { mock(BD::AgentClient) }

    @cloud.should_receive(:create_vm).at_most(3).times.
      with(instance_of(String), @stemcell_a.model.cid, {}, net, nil, {}).
      and_return(*vm_cids)

    BD::AgentClient.should_receive(:new).at_most(3).times.and_return(*agents)

    agents.each do |agent|
      initial_state = {
        "deployment" => "mycloud",
        "resource_pool" => "package_compiler",
        "networks" => net
      }

      agent.should_receive(:wait_until_ready).at_most(6).times
      agent.should_receive(:apply).with(initial_state).at_most(6).times
      agent.should_receive(:compile_package).at_most(6).times do |*args|
        name = args[2]
        dot = args[3].rindex(".")
        version, build = args[3][0..dot-1], args[3][dot+1..-1]

        package = BD::Models::Package.find(:name => name, :version => version)
        args[0].should == package.blobstore_id
        args[1].should == package.sha1

        args[4].should be_a(Hash)

        {
          "result" => {
            "sha1" => "compiled #{package.id}",
            "blobstore_id" => "blob #{package.id}"
          }
        }
      end
    end

    @j_dea.should_receive(:use_compiled_package).exactly(6).times

    vm_cids.each do |vm_cid|
      @cloud.should_receive(:delete_vm).at_most(1).times.with(vm_cid)
    end

    @network.should_receive(:release).at_most(@n_workers).times
    @director_job.should_receive(:task_checkpoint).once

    compiler = make(@plan)

    @package_set_a.each do |package|
      compiler.should_receive(:with_compile_lock).
          with(package.id, @stemcell_a.model.id).and_yield
    end

    compiler.compile
    compiler.compilations_performed.should == 6

    @package_set_a.each do |package|
      package.compiled_packages.size.should >= 1
    end
  end

  it "should make sure a parallel deployment did not compile a package already" do
    package = BDM::Package.make
    stemcell = BDM::Stemcell.make

    task = BD::CompileTask.new(package, stemcell)
    task.dependency_key = "[]"

    compiler = make(@plan)
    callback = nil
    compiler.should_receive(:with_compile_lock).
        with(package.id, stemcell.id) do |&block|
      callback = block
    end
    compiler.compile_package(task)

    compiled_package = BDM::CompiledPackage.make(
        :package => package, :stemcell => stemcell, :dependency_key => "[]")

    callback.call

    task.compiled_package.should == compiled_package
  end

  describe "the global blobstore" do
    let(:package) { BDM::Package.make }
    let(:stemcell) { BDM::Stemcell.make }
    let(:task) { BD::CompileTask.new(package, stemcell) }
    let(:compiler) { make(@plan) }

    before(:each) do
      package.fingerprint = "fingerprint"
      package.save
      stemcell.sha1 = "shawone"
      stemcell.save

      task.dependency_key = "[]"

      BD::Config.stub(:use_global_blobstore?).and_return(true)
    end

    it "should check if compiled package is in global blobstore" do
      callback = nil
      compiler.should_receive(:with_compile_lock).
          with(package.id, stemcell.id) do |&block|
        callback = block
      end

      BD::BlobUtil.should_receive(:exists_in_global_cache?).with(package, stemcell).and_return(true)
      BD::BlobUtil.should_not_receive(:save_to_global_cache)
      compiler.stub(:prepare_vm)
      BDM::CompiledPackage.stub(:create)

      compiler.compile_package(task)
      callback.call
    end

    it "should save compiled package to global cache if not exists" do
      callback = nil
      compiler.should_receive(:with_compile_lock).
          with(package.id, stemcell.id) do |&block|
        callback = block
      end

      compiled_package = mock("compiled package", package: package, stemcell: stemcell, blobstore_id: "some blobstore id")
      BD::BlobUtil.should_receive(:exists_in_global_cache?).with(package, stemcell).and_return(false)
      BD::BlobUtil.should_receive(:save_to_global_cache).with(compiled_package)
      compiler.stub(:prepare_vm)
      BDM::CompiledPackage.stub(:create).and_return(compiled_package)

      compiler.compile_package(task)
      callback.call
    end

    it "only checks the global cache if Config.use_global_blobstore? is set" do
      BD::Config.stub(:use_global_blobstore?).and_return(false)

      callback = nil
      compiler.should_receive(:with_compile_lock).
          with(package.id, stemcell.id) do |&block|
        callback = block
      end

      BD::BlobUtil.should_not_receive(:exists_in_global_cache?)
      BD::BlobUtil.should_not_receive(:save_to_global_cache)
      compiler.stub(:prepare_vm)
      BDM::CompiledPackage.stub(:create)

      compiler.compile_package(task)
      callback.call
    end
  end




end

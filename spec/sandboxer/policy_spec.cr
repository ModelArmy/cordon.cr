require "../spec_helper"

describe Cordon::Policy do
  describe ".new" do
    it "defaults to empty path lists" do
      policy = Cordon::Policy.new
      policy.read_only_paths.should be_empty
      policy.read_write_paths.should be_empty
      policy.tmpfs_paths.should be_empty
      policy.unset_env.should be_empty
      policy.env.should be_empty
    end

    it "defaults allow_network to false" do
      Cordon::Policy.new.allow_network?.should be_false
    end

    it "defaults new_session to true" do
      Cordon::Policy.new.new_session?.should be_true
    end

    it "defaults working_dir to nil" do
      Cordon::Policy.new.working_dir.should be_nil
    end
  end

  describe ".build" do
    it "yields a policy and returns it configured" do
      policy = Cordon::Policy.build do |p|
        p.read_only "/usr/share"
        p.read_write "/tmp/work"
        p.tmpfs "/tmp/scratch"
        p.allow_network = true
        p.working_dir = "/tmp/work"
        p.env["FOO"] = "bar"
      end
      policy.read_only_paths.should eq(["/usr/share"])
      policy.read_write_paths.should eq(["/tmp/work"])
      policy.tmpfs_paths.should eq(["/tmp/scratch"])
      policy.allow_network?.should be_true
      policy.working_dir.should eq("/tmp/work")
      policy.env["FOO"].should eq("bar")
    end
  end

  describe "#read_only / #read_write / #tmpfs" do
    it "accepts multiple paths in one call" do
      policy = Cordon::Policy.build do |p|
        p.read_only "/a", "/b"
        p.read_write "/c", "/d"
        p.tmpfs "/e", "/f"
      end
      policy.read_only_paths.should eq(["/a", "/b"])
      policy.read_write_paths.should eq(["/c", "/d"])
      policy.tmpfs_paths.should eq(["/e", "/f"])
    end
  end

  describe ".from_json / #to_json" do
    it "round-trips a policy through JSON" do
      json = %({"read_only_paths":["/usr/share"],"read_write_paths":["/tmp"],"tmpfs_paths":[],"allow_network":false,"working_dir":null,"env":{},"unset_env":[],"new_session":true})
      policy = Cordon::Policy.from_json(json)
      policy.read_only_paths.should eq(["/usr/share"])
      policy.read_write_paths.should eq(["/tmp"])
      policy.allow_network?.should be_false
    end

    it "deserialises allow_network from JSON" do
      policy = Cordon::Policy.from_json(%({"allow_network":true}))
      policy.allow_network?.should be_true
    end
  end

  describe "#merge" do
    it "unions path arrays without duplicates" do
      a = Cordon::Policy.build { |p| p.read_only "/usr/share", "/etc/myapp" }
      b = Cordon::Policy.build { |p| p.read_only "/etc/myapp", "/opt/data" }
      a.merge(b).read_only_paths.should eq(["/usr/share", "/etc/myapp", "/opt/data"])
    end

    it "unions all path list types" do
      a = Cordon::Policy.build { |p| p.read_write "/tmp/a"; p.tmpfs "/run/a" }
      b = Cordon::Policy.build { |p| p.read_write "/tmp/b"; p.tmpfs "/run/b" }
      merged = a.merge(b)
      merged.read_write_paths.should eq(["/tmp/a", "/tmp/b"])
      merged.tmpfs_paths.should eq(["/run/a", "/run/b"])
    end

    it "allow_network is true if either is true" do
      a = Cordon::Policy.build { |p| p.allow_network = false }
      b = Cordon::Policy.build { |p| p.allow_network = true }
      a.merge(b).allow_network?.should be_true
      b.merge(a).allow_network?.should be_true
      a.merge(a).allow_network?.should be_false
    end

    it "new_session is true if either is true" do
      a = Cordon::Policy.new # default true
      b = Cordon::Policy.build { |p| p.new_session = false }
      a.merge(b).new_session?.should be_true
      b.merge(a).new_session?.should be_true
      b.merge(b).new_session?.should be_false
    end

    it "other working_dir wins when set; falls back to self" do
      a = Cordon::Policy.build { |p| p.working_dir = "/tmp/a" }
      b = Cordon::Policy.build { |p| p.working_dir = "/tmp/b" }
      c = Cordon::Policy.new
      a.merge(b).working_dir.should eq("/tmp/b")
      a.merge(c).working_dir.should eq("/tmp/a")
      c.merge(c).working_dir.should be_nil
    end

    it "merges env hashes with other winning on collision" do
      a = Cordon::Policy.build { |p| p.env["FOO"] = "a"; p.env["BAR"] = "shared" }
      b = Cordon::Policy.build { |p| p.env["BAR"] = "b"; p.env["BAZ"] = "b" }
      merged = a.merge(b)
      merged.env["FOO"].should eq("a")
      merged.env["BAR"].should eq("b")
      merged.env["BAZ"].should eq("b")
    end

    it "unions unset_env without duplicates" do
      a = Cordon::Policy.build { |p| p.unset_env.concat(["SECRET", "TOKEN"]) }
      b = Cordon::Policy.build { |p| p.unset_env.concat(["TOKEN", "DEBUG"]) }
      a.merge(b).unset_env.should eq(["SECRET", "TOKEN", "DEBUG"])
    end

    it "returns a new Policy leaving originals unchanged" do
      a = Cordon::Policy.build { |p| p.read_only "/usr/share" }
      b = Cordon::Policy.build { |p| p.read_only "/opt/data" }
      a.merge(b)
      a.read_only_paths.should eq(["/usr/share"])
      b.read_only_paths.should eq(["/opt/data"])
    end
  end
end

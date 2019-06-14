require "functional/helper"
require "tmpdir"

describe "example inheritance profile" do
  include FunctionalHelper

  it "can vendor profile dependencies" do
    prepare_examples("inheritance") do |dir|
      out = inspec("vendor " + dir + " --overwrite")

      out.stdout.must_include "Dependencies for profile #{dir} successfully vendored to #{dir}/vendor"

      File.exist?(File.join(dir, "vendor")).must_equal true
      File.exist?(File.join(dir, "inspec.lock")).must_equal true

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end

  it "can vendor profile dependencies with a relative path" do
    prepare_examples("inheritance") do |dir|
      relative_path = File.join(dir, "../", File.basename(dir))
      out = inspec("vendor " + relative_path + " --overwrite")

      File.exist?(File.join(dir, "vendor")).must_equal true
      File.exist?(File.join(dir, "inspec.lock")).must_equal true
      Dir.glob(File.join(dir, "vendor", "*")).wont_be_empty

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end

  it "can vendor profile dependencies with a backslash in path on Windows" do
    return unless is_windows?

    prepare_examples("inheritance") do |dir|
      dir_with_backslash = File.join(dir, '..\\', File.basename(dir))
      out = inspec("vendor " + dir_with_backslash + " --overwrite")

      File.exist?(File.join(dir, "vendor")).must_equal true
      File.exist?(File.join(dir, "inspec.lock")).must_equal true
      Dir.glob(File.join(dir, "vendor", "*")).wont_be_empty

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end

  it "can vendor profile dependencies from the profile path" do
    prepare_examples("inheritance") do |dir|
      out = inspec("vendor --overwrite", "cd #{dir} &&")

      # this fixes the osx /var symlink to /private/var causing this test to fail
      out.stdout.gsub!("/private/var", "/var")
      out.stdout.must_include "Dependencies for profile #{dir} successfully vendored to #{dir}/vendor"

      File.exist?(File.join(dir, "vendor")).must_equal true
      File.exist?(File.join(dir, "inspec.lock")).must_equal true

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end

  it "can vendor profile dependencies from git" do
    git_depends_path = File.join(profile_path, "git-fetcher", "basic")

    Dir.mktmpdir do |tmpdir|
      FileUtils.cp_r(git_depends_path + "/.", tmpdir)
      File.exist?(File.join(tmpdir, "vendor")).must_equal false

      out = inspec("vendor " + tmpdir + " --overwrite")

      skip_windows!
      out.stdout.must_include "Dependencies for profile #{tmpdir} successfully vendored to #{tmpdir}/vendor"

      File.exist?(File.join(tmpdir, "vendor")).must_equal true
      File.exist?(File.join(tmpdir, "inspec.lock")).must_equal true
      # Check that our vendor directory exists
      Dir.glob(File.join(tmpdir, "vendor", "*")).length.must_equal 1
      # Check that our vendor directory has contents
      Dir.glob(File.join(tmpdir, "vendor", "*", "*")).length.must_be :>=, 8

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end

  it "ensure nothing is loaded from external source if vendored profile is used" do
    prepare_examples("meta-profile") do |dir|
      out = inspec("vendor " + dir + " --overwrite")

      out.stderr.must_equal ""

      assert_exit_code 0, out

      File.exist?(File.join(dir, "vendor")).must_equal true
      File.exist?(File.join(dir, "inspec.lock")).must_equal true

      # TODO: split
      out = inspec("exec " + dir + " -l debug --no-create-lockfile")

      out.stdout.must_include 'Using cached dependency for {:url=>"https://github.com/dev-sec/ssh-baseline/archive/master.tar.gz"'
      out.stdout.must_include 'Using cached dependency for {:url=>"https://github.com/dev-sec/ssl-baseline/archive/master.tar.gz"'
      out.stdout.must_include 'Using cached dependency for {:url=>"https://github.com/chris-rock/windows-patch-benchmark/archive/master.tar.gz"'
      out.stdout.wont_include "Fetching URL:"
      out.stdout.wont_include "Fetched archive moved to:"

      out.stderr.must_equal ""

      skip_windows!
      assert_exit_code 100, out
    end
  end

  it "ensure json/check command do not fetch remote profiles if vendored" do
    prepare_examples("profile") do |dir|
      out = inspec("vendor " + dir + " --overwrite")

      out.stderr.must_equal ""

      assert_exit_code 0, out

      # TODO: split
      out = inspec("json " + dir + " --output " + dst.path)

      hm = JSON.load(File.read(dst.path))
      hm["name"].must_equal "profile"
      hm["controls"].length.must_be :>=, 4

      # out.stdout.scan(/Copy .* to cache directory/).length.must_equal 3
      # out.stdout.scan(/Dependency does not exist in the cache/).length.must_equal 1
      out.stdout.scan(/Fetching URL:/).length.must_equal 0

      out.stderr.must_equal ""

      assert_exit_code 0, out

      # TODO: split
      # execute check command
      out = inspec("check " + dir + " -l debug")

      out.stdout.scan(/Fetching URL:/).length.must_equal 0

      assert_exit_code 0, out
    end
  end

  it "use lockfile in tarball" do
    prepare_examples("meta-profile") do |dir|
      # ensure the profile is vendored and packaged as tar
      out = inspec("vendor " + dir + " --overwrite")

      out.stderr.must_equal ""

      assert_exit_code 0, out

      # TODO: split
      out = inspec("archive " + dir + " --overwrite")

      out.stderr.must_equal ""

      assert_exit_code 0, out

      # TODO: split
      # execute json command
      out = inspec("json meta-profile-0.2.0.tar.gz -l debug")

      out.stdout.scan(/Fetching URL:/).length.must_equal 0
      out.stdout.wont_match(/Fetching URL:/)

      assert_exit_code 0, out
    end
  end

  it "can move vendor files into custom vendor cache" do
    prepare_examples("meta-profile") do |dir|
      out = inspec("vendor " + dir + " --overwrite")

      File.exist?(File.join(dir, "vendor")).must_equal true
      File.exist?(File.join(dir, "inspec.lock")).must_equal true
      File.exist?(File.join(dir, "vendor_cache")).must_equal false

      out.stderr.must_equal ""

      assert_exit_code 0, out

      # TODO: split
      # Run `inspec exec` to create vendor cache
      inspec("exec " + dir + " --vendor-cache " + dir + "/vendor_cache")
      # TODO: capture out and test exit/stderr?

      File.exist?(File.join(dir, "vendor_cache")).must_equal true
      vendor_files = Dir.entries("#{dir}/vendor/").sort
      vendor_cache_files = Dir.entries("#{dir}/vendor_cache/").sort
      vendor_files.must_equal vendor_cache_files
    end
  end

  it "vendors profiles when using a local path" do
    local_depends_path = File.join(profile_path, "local-depends")
    dir_profile_path = File.join(profile_path, "complete-profile")
    tar_profile_path = File.join(profile_path,
      "archived-profiles",
      "tar_profile-1.0.0.tar.gz")
    zip_profile_path = File.join(profile_path,
      "archived-profiles",
      "zip_profile-1.0.0.zip")

    Dir.mktmpdir do |tmpdir|
      [dir_profile_path, tar_profile_path, zip_profile_path].each do |profile|
        included_tmpdir = File.join(tmpdir, File.basename(profile))
        FileUtils.cp_r(profile, included_tmpdir)
      end

      profile_tmpdir = File.join(tmpdir, File.basename(local_depends_path))
      FileUtils.cp_r(local_depends_path + "/.", profile_tmpdir)

      out = inspec("vendor " + profile_tmpdir + " --overwrite")

      vendor_list = Dir.glob(File.join(profile_tmpdir, "vendor", "*"))
      vendor_list.length.must_equal 3
      vendor_list.each do |entry|
        # confirm archives were extracted into folders
        File.directory?(entry).must_equal true
        Dir.glob(File.join(entry, "*")).length.must_be(:>=, 1)
      end

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end

  it "extracts archives in vendor directory when present" do
    archive_depends_path = File.join(profile_path, "archive-depends")

    Dir.mktmpdir do |tmpdir|
      FileUtils.cp_r(archive_depends_path + "/.", tmpdir)

      out = inspec("vendor " + tmpdir + " --overwrite")

      Dir.glob(File.join(tmpdir, "vendor", "*")).each do |file|
        file.wont_match(/(\.tar.*$|\.zip$)/)
      end

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end

  it "can vendor profile with required inputs" do
    archive_depends_path = File.join(profile_path, "profile-with-required-inputs")

    Dir.mktmpdir do |tmpdir|
      FileUtils.cp_r(archive_depends_path + "/.", tmpdir)

      out = inspec("vendor " + tmpdir)

      out.stderr.must_equal ""

      assert_exit_code 0, out
    end
  end
end

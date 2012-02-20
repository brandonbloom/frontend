require 'spec_helper'

describe SimpleMailer do

  let(:vcs_url) { "https://github.com/arohner/circle-dummy-project" }
  let(:vcs_revision) { "abcdef0123456789" }

  let(:author) { User.create(:name => "Bob", :email => "author@test.com") } # default emails prefs

  let(:lover) { User.create(:name => "Bob",
                            :email => "lover@test.com",
                            :email_preferences => {
                              "on_fail" => ["all"],
                              "on_success" => ["all"],
                            })}

  let(:hater) { User.create(:name => "Bob", :email => "hater@test.com", :email_preferences => {}) }
  let(:users) { [author, hater, lover] }

  let!(:project) { Project.unsafe_create(:vcs_url => vcs_url, :users => users) }

  let(:out1) { { "type" => "out", "time" => nil, "message" => "a message" } }
  let(:out2) { { "type" => "out", "time" => nil, "message" => "another message" } }
  let(:outs) { [out1, out2] }

  let(:successful_log) { ActionLog.create(:type => "test", :name => "true", :exit_code => 0, :out => outs, :end_time => Time.now) }
  let(:setup_log) { ActionLog.create(:type => "setup", :name => "touch setup", :exit_code => 0, :out => outs, :end_time => Time.now) }
  let(:failing_log) { ActionLog.create(:type => "test", :name => "false", :exit_code => 127, :out => outs, :end_time => Time.now) }
  let(:infra_log) { ActionLog.create(:type => "test", :name => "false", :out => [], :infrastructure_fail => true, :end_time => Time.now) }
  let(:timedout_log) { ActionLog.create(:type => "test", :name => "false", :exit_code => 127, :out => outs, :timedout => true, :end_time => Time.now) }

  let(:std_attrs) do
    {
      :vcs_url => vcs_url,
      :start_time => Time.now - 10.minutes,
      :stop_time => Time.now,
      :branch => "remotes/origin/my_branch",
      :vcs_revision => vcs_revision,
      :subject => "That's right, I wrote some code",
      :committer_email => author.email,
      :build_num => 1,
      :project => project
    }
  end

  let(:successful_build) do
    Build.unsafe_create(std_attrs.merge(:action_logs => [setup_log, successful_log],
                                        :failed => false))
  end

  let(:started_by_UI) do
    Build.unsafe_create(std_attrs.merge(:action_logs => [setup_log, successful_log],
                                        :why => "trigger",
                                        :user => lover,
                                        :failed => false))
  end

  let(:failing_build) do
    Build.unsafe_create(std_attrs.merge(:action_logs => [setup_log, successful_log, failing_log],
                                        :failed => true))
  end

  let(:infra_build) do
    Build.unsafe_create(std_attrs.merge(:action_logs => [],
                                        :failed => true,
                                        :infrastructure_fail => true))
  end

  let(:timedout_build) do
    Build.unsafe_create(std_attrs.merge(:action_logs => [setup_log, failing_log],
                                        :failed => true,
                                        :timedout => true))
  end

  let(:no_tests_build) do
    Build.unsafe_create(std_attrs.merge(:action_logs => [setup_log],
                                        :failed => false))
  end

  #  let(:fixed_build) { Build.create(:vcs_url => vcs_url, :parent_build => [failing_build]

  shared_examples "an email" do |build_sym, subject_regexes, body_regexes|

    let(:build) { send(build_sym) }
    let!(:mails) do
      SimpleMailer.post_build_email_hook(build)
      ActionMailer::Base.deliveries
    end

    let(:mail) { mails.first }
    let(:html) { mail.body.parts.find {|p| p.content_type.match /html/}.body.raw_source }
    let(:text) { mail.body.parts.find {|p| p.content_type.match /plain/}.body.raw_source }
    let(:build_report) { "http://circlehost:3000/gh/" + build.project.github_project_name + '/' + build.build_num.to_s }

    it "should send one email" do
      ActionMailer::Base.deliveries.length.should == 1
    end

    it "should be sent to the right users" do
      mail.to.should include lover.email
      mail.to.should include author.email
      mail.to.should_not include hater.email
    end

    subject_regexes.each do |r|
      it "should check the subject's contents" do
        mail.subject.should match r
      end
    end

    body_regexes.each do |r|
      it "should check the subject's body" do
        html.should match r
        text.should match r
      end
    end

    it "should have the right subject" do
      mail.subject.should include ": arohner/circle-dummy-project #1 by author: That's right, I wrote some code"
      mail.subject.should
    end

    it "should be from the right person" do
      mail.from.should == ["builds@circleci.com"]
    end

    it "should have text and multipart" do
      mail.body.parts.length.should == 2
    end

    it "should have a link to the build report" do
      html.should have_tag("a", :text => "Read the full build report", :href => build_report)
      text.should include "Read the full build report: #{build_report}"
    end

    it "should list the revision number" do
      html.should match /Commit abcdef0123456789/i
    end

    it "should list the commands" do
      unless build.infrastructure_fail
        build.logs.length.should > 0
      end

      build.action_logs.length.should == build.logs.length
      build.logs.each do |l|
        html.should include l.command
        text.should include l.command
      end
    end
  end


  describe "the contents and recipients of the emails" do

    describe "success email" do
      it_should_behave_like("an email",
                            :successful_build,
                            [/^Success:/],
                            [/has passed all its tests!/,
                             /These commands were run, and were all successful:/]) do
      end
    end

    describe "failing email" do
      it_should_behave_like("an email",
                            :failing_build,
                            [/^Failed:/],
                            [/has failed its tests!/,
                             /The rest of your commands were successful:/,
                             /Output:/,
                             /a message/,
                             /another message/,
                             /a messageanother message/, # checks whitespace
                             /Exit code: 127/]) do
      end
    end

    describe "no tests email" do
      it_should_behave_like("an email",
                            :no_tests_build,
                            [/^No tests:/],
                            [/did not run any tests, because it has no test commands!/,
                             /The rest of your commands were successful:/]) do
      end
    end

    describe "infrastructure fail email" do
      it_should_behave_like("an email",
                            :infra_build,
                            [/^Circle bug:/],
                            [/There was a bug in Circle\'s infrastructure that led to a problem testing commit/,
                             /We have been notified and will fix the problem as soon as possible./]) do
        it "should CC us" do
          mail.cc.should == ["engineering@circleci.com"]
        end
      end
    end

    describe "timedout email" do
      it_should_behave_like("an email",
                            :timedout_build,
                            [/^Timed out:/],
                            [/timed out during testing, after 20 minutes without output./]) do
      end
    end

    describe "builds started from the UI" do
      it "should only be sent to the person who started it" do
        SimpleMailer.post_build_email_hook(started_by_UI);
        mail = ActionMailer::Base.deliveries[0]
        mail.to.should == [lover.email]
        mail.cc.should == []
      end
    end


    it "should send a 'fixed' email to the author" do
      pending
    end

    it "should handle the branch stuff" do
      pending
    end
  end

  it "should send a first email" do
    pending # check the contents
  end


  describe "real mail" do
    before :all do
      ActionMailer::Base.delivery_method = :smtp
    end

    after :all do
      ActionMailer::Base.delivery_method = :test
    end

    it "should work through mailgun" do
      token = "[TEST_TOKEN #{Time.now.to_f.to_s}]"

      SimpleMailer.test(:subject => "#{token}: Test that we can send real mail, and that it delivers")

      # check the logs, it should contain that token
      json = RestClient.get "https://api:key-1jtca38b84yhf576s-teo2e5a06n1bl7@api.mailgun.net/v2/circle-test.mailgun.org/log", :params => { :limit => 20 }
      mails = JSON.parse(json)["items"]

      mails.any? { |item| item["message"].include? token }.should == true
    end
  end
end

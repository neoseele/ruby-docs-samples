# Copyright 2016 Google, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative "../sample"
require "rspec"
require "gcloud"

describe "Logging sample" do

  # Simple wait method. Test for condition 5 times, delaying 1 second each time
  def wait_until times: 5, delay: 1, &condition
    times.times do
      return if condition.call
      sleep delay
    end
    raise "Condition not met.  Waited #{times} times with #{delay} sec delay"
  end

  # Frequently used full path to "my_application_log" for test project
  def my_application_log_name
    "projects/#{@project_id}/logs/my_application_log"
  end

  # Returns entries logged to "my_application_log" in the test project
  def my_application_log_entries
    @logging.entries(
      filter: %{logName = "#{my_application_log_name}"},
      order: "timestamp desc"
    )
  end

  # Tests require environment variables:
  #
  #   GCLOUD_PROJECT   ID of your Google Cloud Platform project
  #   BUCKET           Name of Google Cloud Storage bucket to use for log sink
  #   ALT_BUCKET       Name of an alternative bucket to also use for log sink
  #
  before :all do
    @project_id = ENV["GCLOUD_PROJECT"]
    @gcloud     = Gcloud.new @project_id
    @logging    = @gcloud.logging
    @storage    = @gcloud.storage
    @bucket     = @storage.bucket ENV["BUCKET"]
    @alt_bucket = @storage.bucket ENV["ALT_BUCKET"]

    # Cloud Logging needs owner permissions on the buckets used
    @bucket.acl.add_owner "group-cloud-logs@google.com"
    @alt_bucket.acl.add_owner "group-cloud-logs@google.com"
  end

  # Sample code uses project ID "my-gcp-project-id" and bucket
  # names "my-logs-bucket" and "new-destination-bucket"
  #
  # Stub calls to Gcloud library to use our test project and storage buckets
  before :each do
    cleanup!
    allow(Gcloud).to receive(:new).and_call_original
    allow(Gcloud).to receive(:new).with("my-gcp-project-id").and_return(@gcloud)
    allow(@gcloud).to receive(:logging).and_return(@logging)
    allow(@gcloud).to receive(:storage).and_return(@storage)
    allow(@storage).to receive(:create_bucket).and_return(@bucket)
    allow(@storage).to receive(:bucket).with("my-logs-bucket").
                       and_return(@bucket)
    allow(@storage).to receive(:bucket).with("new-destination-bucket").
                       and_return(@alt_bucket)
  end

  # Delete log sink used by code samples if the test created one
  def cleanup!
    test_sink = @logging.sink "my-sink"
    test_sink.delete if test_sink
  end

  it "can create logging client" do
    expect(create_logging_client).to be_a Gcloud::Logging::Project
    expect(create_logging_client.project).to eq @project_id
  end

  it "can list log sinks" do
    expect { list_log_sinks }.not_to output(/my-sink/).to_stdout

    create_log_sink

    expect { list_log_sinks }.to output(/my-sink/).to_stdout
  end

  it "can create log sink" do
    expect(@logging.sink "my-sink").to be nil

    create_log_sink

    expect(@logging.sink "my-sink").not_to be nil
  end

  it "can update log sink" do
    original_destination = "storage.googleapis.com/#{@bucket.id}"
    updated_destination  = "storage.googleapis.com/#{@alt_bucket.id}"

    create_log_sink

    expect(@logging.sink("my-sink").destination).to eq original_destination

    update_log_sink

    expect(@logging.sink("my-sink").destination).to eq updated_destination
  end

  it "can delete log sink" do
    create_log_sink

    expect { list_log_sinks }.to output(/my-sink/).to_stdout

    delete_log_sink

    expect { list_log_sinks }.not_to output(/my-sink/).to_stdout
  end

  it "can list log entries" do
    write_log_entry

    # The code sample queries for entries for "gae_app" resources.
    # The test project may not have App Engine resources.
    # Instead, add a project log entry and change the filter string called.
    allow(@logging).to receive(:entries).
      with(filter: %{resource.type = "gae_app"}).
      and_wrap_original do |m, *args|
        m.call(
          filter: %{logName = "#{my_application_log_name}"},
          order: "timestamp desc"
        )
      end

    timestamp = "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} [^\\\\]+"

    expect { list_log_entries }.to output(
      %r{\[#{timestamp}\] #{my_application_log_name} "Log message"}
    ).to_stdout
  end

  it "can write log entry" do
    current_time = Time.now.to_f

    # Log entries refer to a particular resource
    # Mock the resource to refer to the test project being used
    # Also append the current time to the log message for asserting existence
    allow(@logging).to receive(:write_entries).and_wrap_original do |m, entry|
      # Verify entry payload and resource from sample
      expect(entry.payload).to eq "Log message"
      expect(entry.resource.type).to eq "gae_app"
      expect(entry.resource.labels[:module_id]).to eq "default"
      expect(entry.resource.labels[:version_id]).to eq "20160101t163030"

      # Update entry to log to test resource
      entry.payload += " - current time #{current_time}"
      entry.resource.type = "project"
      entry.resource.labels.clear
      entry.resource.labels[:project_id] = @project_id

      m.call entry
    end

    entries = my_application_log_entries
    entry = entries.detect { |e| e.payload.include? "time #{current_time}" }
    expect(entry).to be nil

    write_log_entry

    # Wait for entry to be queryable
    wait_until do
      my_application_log_entries.any? do |e|
        e.payload == "Log message - current time #{current_time}"
      end
    end

    entries = my_application_log_entries
    entry = entries.detect { |e| e.payload.include? "time #{current_time}" }
    expect(entry).not_to be nil
    expect(entry.payload).to eq "Log message - current time #{current_time}"
    expect(entry.severity).to eq :NOTICE
    expect(entry.log_name).to eq(
      "projects/#{@project_id}/logs/my_application_log"
    )
  end

  it "can delete log" do
    expect { delete_log }.not_to raise_error
  end

  it "can write log entry using Ruby Logger" do
    current_time = Time.now.to_f

    entries = @logging.entries(
      filter: %{logName = "projects/#{@project_id}/logs/my_application_log"},
      order: "timestamp desc"
    )
    entry = entries.detect { |e| e.payload.include? "time #{current_time}" }
    expect(entry).to be nil

    # Hooked up to real test project
    logger = @logging.logger(
      "my_application_log",
      @logging.resource("project", project_id: @project_id)
    )

    # Log entries refer to a particular resource
    # Mock the resource to refer to the test project being used
    # Also append the current time to the log message for asserting existence
    allow(@logging).to receive(:logger) do |name, resource|
      # Verify entry payload and resource from sample
      expect(name).to eq "my_application_log"
      expect(resource.type).to eq "gae_app"
      expect(resource.labels[:module_id]).to eq "default"
      expect(resource.labels[:version_id]).to eq "20160101t163030"
      logger
    end

    # Append unique string to logged message for assertion
    allow(logger).to receive(:info).and_wrap_original do |m, message|
      message += " - current time #{current_time}"
      m.call message
    end

    write_log_entry_using_ruby_logger

    # Wait for entry to be queryable
    wait_until do
      my_application_log_entries.any? do |e|
        e.payload == "Log message - current time #{current_time}"
      end
    end

    entries = my_application_log_entries
    entry = entries.detect { |e| e.payload.include? "time #{current_time}" }
    expect(entry).not_to be nil
    expect(entry.payload).to eq "Log message - current time #{current_time}"
    expect(entry.severity).to eq :INFO
    expect(entry.log_name).to eq(
      "projects/#{@project_id}/logs/my_application_log"
    )
  end
end

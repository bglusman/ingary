#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

ROOT = Pathname.new(__dir__).join("..").expand_path
BASELINE = ROOT.join("scripts/elixir-map-boundary-baseline.json")

PATTERNS = {
  "string_key_entry" => /"[^"\n]+"\s*=>/,
  "string_key_access" => /\[[ \t]*"[^"\n]+"[ \t]*\]/,
  "map_call_string_key" => /Map\.(?:get|put|update|delete|has_key\?)\([^#\n]*"[^"\n]+"/,
  "get_in_string_path" => /get_in\([^#\n]*\[[^\]\n]*"[^"\n]+"/
}.freeze

EXCLUDED_PATH_PREFIXES = [
  "app/lib/wardwright/policy_sandbox/",
  "app/lib/wardwright_web/"
].freeze

def source_files
  files = Dir[ROOT.join("app/lib/wardwright/**/*.ex").to_s]
  files << ROOT.join("app/lib/wardwright.ex").to_s

  files
    .map { |path| Pathname.new(path).relative_path_from(ROOT).to_s }
    .reject { |path| EXCLUDED_PATH_PREFIXES.any? { |prefix| path.start_with?(prefix) } }
    .sort
end

def strip_line_comment(line)
  line.split("#", 2).first || ""
end

def file_counts(path)
  patterns = Hash[PATTERNS.keys.map { |key| [key, 0] }]

  ROOT.join(path).read.each_line do |line|
    next if line.include?("boundary-map-ok")

    code = strip_line_comment(line)
    PATTERNS.each do |name, pattern|
      patterns[name] += code.scan(pattern).length
    end
  end

  {"total" => patterns.values.sum, "patterns" => patterns}
end

def current_counts
  Hash[source_files.map { |path| [path, file_counts(path)] }]
end

def write_baseline!(counts)
  payload = {
    "description" =>
      "Baseline for string-keyed/deep map access in Wardwright Elixir core modules. Reduce counts over time; do not increase them without an intentional boundary review.",
    "excluded_path_prefixes" => EXCLUDED_PATH_PREFIXES,
    "patterns" => PATTERNS.transform_values(&:source),
    "files" => counts
  }

  BASELINE.write(JSON.pretty_generate(payload) + "\n")
  puts "updated #{BASELINE.relative_path_from(ROOT)}"
end

def load_baseline
  JSON.parse(BASELINE.read).fetch("files")
rescue Errno::ENOENT
  abort("#{BASELINE.relative_path_from(ROOT)} is missing; run #{$PROGRAM_NAME} --update-baseline")
end

def format_delta(path, current, baseline)
  "#{path}: #{current.fetch("total")} current, #{baseline.fetch("total")} baseline"
end

counts = current_counts

if ARGV.include?("--update-baseline")
  write_baseline!(counts)
  exit
end

baseline = load_baseline
failed = false

counts.each do |path, current|
  expected = baseline[path]

  if expected.nil?
    next if current.fetch("total").zero?

    warn "#{path}: new core file has #{current.fetch("total")} string-keyed map accesses; parse at the boundary or update the baseline with review"
    failed = true
    next
  end

  next unless current.fetch("total") > expected.fetch("total")

  warn "#{format_delta(path, current, expected)}; reduce the new map access or update the baseline with review"
  failed = true
end

removed_files = baseline.keys - counts.keys
removed_files.each { |path| warn "#{path}: remove stale entry from #{BASELINE.relative_path_from(ROOT)}" }
failed ||= removed_files.any?

abort("elixir map boundary ratchet failed") if failed

top =
  counts
  .sort_by { |_path, data| -data.fetch("total") }
  .first(5)
  .map { |path, data| "#{path}=#{data.fetch("total")}" }
  .join(", ")

puts "elixir map boundary ratchet passed"
puts "top tracked files: #{top}"

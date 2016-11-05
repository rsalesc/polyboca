require 'rubygems'
require 'nokogiri'
require 'zip'
require 'fileutils'
require 'pathname'
require 'optparse'
require 'yaml'
require_relative 'erba'
require_relative 'utils'

$DIR = File.expand_path(File.dirname(__FILE__))
$TEMPLATE_PATH = "#{$DIR}/template"
$STATEMENT_PATH = "description/statement.pdf"
$FILES_PATH = "files/"

def fix_raw(s)
  s
end

def zeropad(s)
  s.to_s.rjust(3, "0")
end

class Problem
  def initialize(obj, dir=Dir.pwd, lang="portuguese", testset="tests")
    @doc = Nokogiri::XML(obj)
    @dir = dir
    @set = @doc.xpath("//judging[1]//testset[@name='#{testset}']")
    @lang = lang
  end

  def get_short_name
    @doc.xpath("//problem/@short-name").first.to_s
  end

  def get_name
    @doc.xpath("//problem/names/name[@language='#{@lang}'][1]/@value").first.to_s
  end

  def get_pdf_path
    p = @doc.xpath("//statements/statement[@type='application/pdf'][@language='#{@lang}'][1]/@path").to_s
    File.expand_path(p,@dir)
  end

  def get_cpu_speed
    @set.xpath("//judging[1]/@cpu-speed").to_s.to_i
  end

  def get_timelimit
    @set.xpath("time-limit[1]/text()").first.to_s.to_i
  end

  def get_memorylimit
    (@set.xpath("memory-limit[1]/text()").first.to_s.to_i/1024/1024).to_i
  end

  def test_count
    @set.xpath("test-count[1]/text()").first.to_s.to_i
  end

  def get_input_pattern
    @set.xpath("input-path-pattern/text()").first.to_s
  end

  def get_answer_pattern
    @set.xpath("answer-path-pattern[1]/text()").first.to_s
  end

  def get_tests
    res = []
    input_pattern = self.get_input_pattern
    answer_pattern = self.get_answer_pattern
    (1..self.test_count).each do |i|
      res << [File.expand_path(input_pattern % i, @dir),
              File.expand_path(answer_pattern % i, @dir),
              i]
    end

    return res
  end

  def get_files
    @doc.xpath("//source/@path | //file/@path") \
      .to_a.map!{|x| File.expand_path(x.to_s, @dir)}
  end

  def get_checker
    node = @doc.xpath("//assets/checker/source").first
    [File.expand_path(node.xpath("@path").to_s, @dir), node.xpath("@type").to_s]
  end

  def get_testlib
    self.get_files.select {|x| x =~ /(.*\/)*testlib\.h$/}[0]
  end
end

class PolyBoca
  attr_accessor :time_mult
  attr_accessor :repetitions
  attr_accessor :source_size
  attr_accessor :output_dir

  def initialize()
    @time_mult = 1
    @repetitions = 1
    @source_size = 512 # in kb
    @output_dir = nil
  end

  def to_boca(poly_zip, short_name=nil)
    poly_zip_final = "#{File.basename(poly_zip, '.*')}_boca.zip"
    final_name = "#{poly_zip_final}"

    if @output_dir.nil? then
        final_name = File.join(File.dirname(poly_zip), final_name)
    else
        final_name = File.join(@output_dir, final_name)
    end

    p final_name

    Dir.mktmpdir{|poly_dir|
      unzip_file(poly_zip, poly_dir)
      poly_f = File.open(File.join(poly_dir, "problem.xml"))
      @p = Problem.new(poly_f, poly_dir)

      # init boca_dir
      Dir.mktmpdir{|boca_dir|
        puts "Temp boca_dir: #{boca_dir}" # debug
        puts

        # prepare bindings
        vars = {
          multiplier: @time_mult,
          clock:  @p.get_cpu_speed,
          reps: @repetitions,
          source_size: @source_size,

          short_name: short_name.nil? ? @p.get_short_name : short_name,
          full_name: @p.get_name,
          statement_path: @p.get_pdf_path.empty? ? "no" : File.basename($STATEMENT_PATH),
          time_limit: @p.get_timelimit,
          memory_limit: @p.get_memorylimit,
          checker_path: File.basename(@p.get_checker[0]),
          checker_lang: @p.get_checker[1],
          checker_content: fix_raw(File.read(@p.get_checker[0])),
          testlib_content: fix_raw(File.read(@p.get_testlib))
        }

        puts "Copying and generating templates..."
        # copy templates
        template_pn = Pathname.new("#{$TEMPLATE_PATH}/")
        Dir.glob("#{$TEMPLATE_PATH}/**/*") do |path|
          if File.file? path then
            path_pn = Pathname.new(path)
            path_dest = File.join(boca_dir, path_pn.relative_path_from(template_pn).to_s)
            if File.extname(path) == ".erb" then
              content = File.read(path)
              rendered = Erba.new(vars).render(content)
              path_dest.gsub!(".erb", "")
              FileUtils.mkdir_p(File.dirname(path_dest))
              File.open(path_dest, "w"){|f| f.write(rendered)}
              puts "- Copying and rendering #{File.basename(path)}"
            else
              copy_file(path, path_dest)
            end
          end
        end

        puts "Copying files (sources and resources)..."
        # copy files
        @p.get_files.each do |path|
          puts "- Copying file #{File.basename(path)}"
          copy_file(path, File.join(boca_dir, $FILES_PATH, File.basename(path)))
        end

        puts "Copying testcases (input and answers)..."
        # copy testcases
        @p.get_tests.each do |t|
          input, output, idx = t
          copy_file(input, File.join(boca_dir, "input", zeropad(idx.to_s)))
          copy_file(output, File.join(boca_dir, "output", zeropad(idx.to_s)))
        end

        puts "Copying PDF statement..."
        # copy statement
        copy_file(@p.get_pdf_path, File.join(boca_dir, $STATEMENT_PATH)) \
          unless @p.get_pdf_path.empty?

        puts "Creating ZIP #{File.basename(final_name)}"
        zf = ZipFileGenerator.new(boca_dir, final_name)
        zf.write
      }
    }
  end

  def to_jude(poly_zip)
    poly_zip_final = "#{File.basename(poly_zip, '.*')}_jude.zip"
    final_name = "#{poly_zip_final}"

    if @output_dir.nil? then
        final_name = File.join(File.dirname(poly_zip), final_name)
    else
        final_name = File.join(@output_dir, final_name)
    end

    p final_name

    Dir.mktmpdir{|poly_dir|
      unzip_file(poly_zip, poly_dir)
      poly_f = File.open(File.join(poly_dir, "problem.xml"))
      @p = Problem.new(poly_f, poly_dir)

      Dir.mktmpdir{|jude_dir|
        puts "Temp jude dir: #{jude_dir}"
        puts

        # prepare jude.yml
        vars = {
          "weight" => 1,
          "limits" => {
            "source" => @source_size,
            "time" => @p.get_timelimit,
            "memory" => @p.get_memorylimit,
            "timeMultiplier" => @time_mult
          },
          "datasets" => [
            {
              "percentage" => 1,
              "path" => "main",
              "name" => "main"
            }
          ]
        }

        # copy cplusplus+testlib checker
        checker_path = @p.get_checker[0]
        puts "Copying checker #{File.basename(checker_path)}..."

        copy_file(checker_path, File.join(jude_dir, "checker.cpp"))

        # copy testcases
        puts "Copying testcases to a single dataset called \"main\"..."
        @p.get_tests.each do |t|
          input, output, idx = t
          copy_file(input, File.join(jude_dir, "tests/main", "#{zeropad(idx.to_s)}.in"))
          copy_file(output, File.join(jude_dir, "tests/main", "#{zeropad(idx.to_s)}.out"))
        end

        puts "Copying PDF statement..."
        # copy statement

        if not @p.get_pdf_path.empty? then
          copy_file(@p.get_pdf_path, File.join(jude_dir, "statement.pdf"))
          vars["statement"] = "statement.pdf"
        end

        # save jude.yml
        File.write(File.join(jude_dir, "jude.yml"), vars.to_yaml)

        puts "Creating ZIP #{File.basename(final_name)}"
        zf = ZipFileGenerator.new(jude_dir, final_name)
        zf.write
      }
    }
  end
end

if __FILE__ == $0 then
    to_process = []
    poly = PolyBoca.new
    short_name = nil
    target = nil
    OptionParser.new do |parser|
        parser.banner = "Usage: #{$0} [options]"

        parser.on("-t", "--target FORMAT", "Specify the target format") do |format|
          target = format
        end

        parser.on("-f", "--file PATTERN", 
            "Convert every file that matches PATTERN (glob-like pattern)") do |pattern|
            to_process = Dir.glob(pattern).select{|x| File.file?(x)}
        end

        parser.on("-m", "--multiplier MULTIPLIER",
            "Set time multiplier to be applied to the TLs") do |mult|
            poly.time_mult = mult
        end

        parser.on("-r", "--runs NRUNS",
            "Number of times a solution should be run against a test") do |nruns|
            poly.repetitions = nruns
        end

        parser.on("--source-limit LIMIT",
            "Source limit in KB") do |limit|
            poly.source_size = limit
        end

        parser.on("-d", "--dir DIR",
            "Specify custom output dir") do |dir|
            FileUtils.mkdir_p(dir) unless File.directory?(dir)
            poly.output_dir = dir
        end

        parser.on("-s", "--short SHORT_NAME",
            "Specify problem short name used by BOCA") do |short|
          short_name = short
        end
    end.parse!

    to_process.each do |x|
            puts "============ Processing package #{x}..."
            puts "Target Format: #{target}"
            if target != "jude" then
              poly.to_boca(x, short_name)
            else
              poly.to_jude(x)
            end 
    end
end

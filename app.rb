require 'rubygems'
require 'nokogiri'
require 'zip'
require 'fileutils'
require 'pathname'
require_relative 'erba'
require_relative 'utils'

$TEMPLATE_PATH = "template"
$STATEMENT_PATH = "description/statement.pdf"
$FILES_PATH = "files/"

def fix_raw(s)
  s
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
  attr_accessor :clock
  attr_accessor :repetitions
  attr_accessor :source_size

  def initialize()
    @time_multiplier = 1
    @clock = false
    @repetitions = 1
    @source_size = 512 # in kb
  end

  def to_boca(poly_zip)
    poly_zip_ext = File.extname(poly_zip)
    final_name = poly_zip.gsub(poly_zip_ext, "_boca#{poly_zip_ext}")

    Dir.mktmpdir{|poly_dir|
      unzip_file(poly_zip, poly_dir)
      poly_f = File.open(File.join(poly_dir, "problem.xml"))
      @p = Problem.new(poly_f, poly_dir)

      # init boca_dir
      Dir.mktmpdir{|boca_dir|
        p boca_dir # debug

        # prepare bindings
        vars = {
          multiplier: @time_multiplier,
          clock: @clock ? @p.get_cpu_speed : 0,
          reps: @repetitions,
          source_size: @source_size,

          short_name: @p.get_short_name,
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
          copy_file(input, File.join(boca_dir, "input", idx.to_s))
          copy_file(output, File.join(boca_dir, "output", idx.to_s))
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
end

if __FILE__ == $0 then
    poly = PolyBoca.new
    poly.to_boca("arvore.zip")
end

#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2010-2013 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'phusion_passenger/platform_info'

module PhusionPassenger

module PlatformInfo
private
	def self.detect_compiler_options(language, flags)
		case language
		when :c
			compiler  = [cc, flags, ENV['EXTRA_CFLAGS']]
			extension = "c"
		when :cxx
			compiler  = [cxx, flags, ENV['EXTRA_CXXFLAGS']]
			extension = "cpp"
		else
			raise ArgumentError, "Unsupported language #{language.inspect}"
		end
		return [compiler.compact.join(" ").strip, extension]
	end
	private_class_method :detect_compiler_options

	def self.run_compiler(description, command, source_file, source)
		if verbose?
			message = "#{description}\n" <<
				"Running: #{command}\n"
			if source.strip.empty?
				message << "Source file is empty."
			else
				message << "Source file contains:\n" <<
					"-------------------------\n" <<
					unindent(source) <<
					"\n-------------------------"
			end
			log(message)
			result = system(command)
		else
			result = system("(#{command}) >/dev/null 2>/dev/null")
		end
		if result.nil?
			log("Command could not be executed!")
			return false
		elsif result
			log("Check suceeded")
			return true
		else
			log("Check failed with exit status #{$?.exitstatus}")
			return false
		end
	end
	private_class_method :run_compiler

public
	def self.cc
		return string_env('CC', 'gcc')
	end
	
	def self.cxx
		return string_env('CXX', 'g++')
	end

	def self.cc_is_clang?
		`#{cc} --version 2>&1` =~ /clang version/
	end
	memoize :cc_is_clang?

	def self.cxx_is_clang?
		`#{cxx} --version 2>&1` =~ /clang version/
	end
	memoize :cxx_is_clang?


	def self.try_compile(description, language, source, flags = nil)
		compiler, extension = detect_compiler_options(language, flags)
		create_temp_file("passenger-compile-check.#{extension}") do |filename, f|
			f.puts(source)
			f.close
			begin
				command = "#{compiler} -c '#{filename}' -o '#{filename}.o'"
				return run_compiler(description, command, filename, source)
			ensure
				File.unlink("#{filename}.o") rescue nil
			end
		end
	end
	
	def self.try_link(description, language, source, flags = nil)
		compiler, extension = detect_compiler_options(language, flags)
		create_temp_file("passenger-link-check.#{extension}") do |filename, f|
			f.puts(source)
			f.close
			begin
				command = "#{compiler} '#{filename}' -o '#{filename}.out' #{ENV['EXTRA_LDFLAGS']}".strip
				return run_compiler(description, command, filename, source)
			ensure
				File.unlink("#{filename}.out") rescue nil
			end
		end
	end
	
	def self.try_compile_and_run(description, language, source, flags = nil)
		compiler, extension = detect_compiler_options(language, flags)
		create_temp_file("passenger-run-check.#{extension}") do |filename, f|
			f.puts(source)
			f.close
			begin
				command = "#{compiler} '#{filename}' -o '#{filename}.out'"
				if run_compiler(description, command, filename, source)
					log("Running #{filename.out}")
					begin
						output = `'#{filename}.out' 2>&1`
					rescue SystemCallError => e
						log("Command failed: #{e}")
						return false
					end
					status = $?.exitstatus
					log("Command exited with status #{status}. Output:\n--------------\n#{output}\n--------------")
					return status == 0
				else
					return false
				end
			ensure
				File.unlink("#{filename}.out") rescue nil
			end
		end
	end


	# Checks whether the compiler supports "-arch #{arch}".
	def self.compiler_supports_architecture?(arch)
		return try_compile("Checking for C compiler '-arch' support",
			:c, '', "-arch #{arch}")
	end
	
	def self.compiler_supports_visibility_flag?
		return false if RUBY_PLATFORM =~ /aix/
		return try_compile("Checking for C compiler '-fvisibility' support",
			:c, '', '-fvisibility=hidden')
	end
	memoize :compiler_supports_visibility_flag?, true
	
	def self.compiler_supports_wno_attributes_flag?
		return try_compile("Checking for C compiler '-Wno-attributes' support",
			:c, '', '-Wno-attributes')
	end
	memoize :compiler_supports_wno_attributes_flag?, true

	def self.compiler_supports_wno_missing_field_initializers_flag?
		return try_compile("Checking for C compiler '-Wno-missing-field-initializers' support",
			:c, '', '-Wno-missing-field-initializers')
	end
	memoize :compiler_supports_wno_missing_field_initializers_flag?, true
	
	def self.compiler_supports_no_tls_direct_seg_refs_option?
		return try_compile("Checking for C compiler '-mno-tls-direct-seg-refs' support",
			:c, '', '-mno-tls-direct-seg-refs')
	end
	memoize :compiler_supports_no_tls_direct_seg_refs_option?, true
	
	# Returns whether compiling C++ with -fvisibility=hidden might result
	# in tons of useless warnings, like this:
	# http://code.google.com/p/phusion-passenger/issues/detail?id=526
	# This appears to be a bug in older g++ versions:
	# http://gcc.gnu.org/ml/gcc-patches/2006-07/msg00861.html
	# Warnings should be suppressed with -Wno-attributes.
	def self.compiler_visibility_flag_generates_warnings?
		if RUBY_PLATFORM =~ /linux/ && `#{cxx} -v 2>&1` =~ /gcc version (.*?)/
			return $1 <= "4.1.2"
		else
			return false
		end
	end
	memoize :compiler_visibility_flag_generates_warnings?, true
	
	def self.has_math_library?
		return try_link("Checking for -lmath support",
			:c, "int main() { return 0; }\n", '-lmath')
	end
	memoize :has_math_library?, true
	
	def self.has_alloca_h?
		return try_compile("Checking for alloca.h",
			:c, '#include <alloca.h>')
	end
	memoize :has_alloca_h?, true
	
	# C compiler flags that should be passed in order to enable debugging information.
	def self.debugging_cflags
		# According to OpenBSD's pthreads man page, pthreads do not work
		# correctly when an app is compiled with -g. It recommends using
		# -ggdb instead.
		#
		# In any case we'll always want to use -ggdb for better GDB debugging.
		if cc_is_clang? || cxx_is_clang?
			return '-g'
		else
			return '-ggdb'
		end
	end

	def self.dmalloc_ldflags
		if !ENV['DMALLOC_LIBS'].to_s.empty?
			return ENV['DMALLOC_LIBS']
		end
		if RUBY_PLATFORM =~ /darwin/
			['/opt/local', '/usr/local', '/usr'].each do |prefix|
				filename = "#{prefix}/lib/libdmallocthcxx.a"
				if File.exist?(filename)
					return filename
				end
			end
			return nil
		else
			return "-ldmallocthcxx"
		end
	end
	memoize :dmalloc_ldflags

	def self.electric_fence_ldflags
		if RUBY_PLATFORM =~ /darwin/
			['/opt/local', '/usr/local', '/usr'].each do |prefix|
				filename = "#{prefix}/lib/libefence.a"
				if File.exist?(filename)
					return filename
				end
			end
			return nil
		else
			return "-lefence"
		end
	end
	memoize :electric_fence_ldflags
	
	def self.export_dynamic_flags
		if RUBY_PLATFORM =~ /linux/
			return '-rdynamic'
		else
			return nil
		end
	end


	def self.make
		return string_env('MAKE', find_command('make'))
	end
	memoize :make, true

	def self.gnu_make
		if result = string_env('GMAKE')
			return result
		else
			result = find_command('gmake')
			if !result
				result = find_command('make')
				if result
					if `#{result} --version 2>&1` =~ /GNU/
						return result
					else
						return nil
					end
				else
					return nil
				end
			else
				return result
			end
		end
	end
	memoize :gnu_make, true
end

end # module PhusionPassenger

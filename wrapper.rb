$: << "test_scripts/#{CustomScript}"
load("test_scripts/#{CustomScript}.rb")
puts RubyHook.new.respond_to(1, 2)

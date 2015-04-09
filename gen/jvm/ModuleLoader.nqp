# This file automatically generated by tools/build/gen-cat.nqp

# From 'src/vm/jvm/ModuleLoaderVMConfig.nqp'

role Perl6::ModuleLoaderVMConfig {
    method vm_search_paths() {
        my @search_paths;
        for nqp::jvmclasspaths() -> $path {
            @search_paths.push($path);
        }
        @search_paths
    }
    
    # Locates files we could potentially load for this module.
    method locate_candidates($module_name, @prefixes, :$file) {
        # If its name contains a slash or dot treat is as a path rather than a package name.
        my @candidates;
        if nqp::defined($file) {
            $file := nqp::gethllsym('perl6', 'ModuleLoader').absolute_path($file);
            if nqp::stat($file, 0) {
                my %cand;
                %cand<key> := $file;
                my $dot := nqp::rindex($file, '.');
                my $ext := $dot >= 0 ?? nqp::substr($file, $dot, nqp::chars($file) - $dot) !! '';
                if $ext eq 'class' || $ext eq 'jar' {
                    %cand<load> := $file;
                }
                else {
                    %cand<pm> := $file;
                }
                @candidates.push(%cand);
            }
        }
        else {
            # Assemble various files we'd look for.
            my $base_path  := nqp::join('/', nqp::split('::', $module_name));
            my $class_path := $base_path ~ '.class';
            my $jar_path   := $base_path ~ '.jar';
            my $pm_path    := $base_path ~ '.pm';
            my $pm6_path   := $base_path ~ '.pm6';
            
            # Go through the prefixes and build a candidate list.
            for @prefixes -> $prefix {
                $prefix := nqp::gethllsym('perl6', 'ModuleLoader').absolute_path(~$prefix);
                my $have_pm    := nqp::stat("$prefix/$pm_path", 0);
                my $have_pm6   := nqp::stat("$prefix/$pm6_path", 0);
                my $have_class := nqp::stat("$prefix/$class_path", 0);
                my $have_jar   := nqp::stat("$prefix/$jar_path", 0);
                if $have_pm6 {
                    # if there are both .pm and .pm6 we assume that
                    # the former is a Perl 5 module and use the latter
                    $have_pm := 1;
                    $pm_path := $pm6_path;
                }
                if $have_jar {
                    # might be good to error here?
                    $have_class := 1;
                    $class_path := $jar_path;
                }
                if $have_pm {
                    my %cand;
                    %cand<key> := "$prefix/$pm_path";
                    %cand<pm>  := "$prefix/$pm_path";
                    if $have_class && nqp::stat("$prefix/$class_path", 7)
                                    >= nqp::stat("$prefix/$pm_path", 7) {
                        %cand<load> := "$prefix/$class_path";
                    }
                    @candidates.push(%cand);
                }
                elsif $have_class {
                    my %cand;
                    %cand<key>  := "$prefix/$class_path";
                    %cand<load> := "$prefix/$class_path";
                    @candidates.push(%cand);
                }
            }
        }
        @candidates
    }
    
    # Finds a setting to load.
    method find_setting($setting_name) {
        my $path := "$setting_name.setting.jar";
        my @prefixes := self.search_path();
        for @prefixes -> $prefix {
            $prefix := nqp::gethllsym('perl6', 'ModuleLoader').absolute_path(~$prefix);
            if nqp::stat("$prefix/$path", 0) {
                $path := "$prefix/$path";
                last;
            }
        }
        $path
    }
}
# From 'src/Perl6/ModuleLoader.nqp'

my $DEBUG := +nqp::ifnull(nqp::atkey(nqp::getenvhash(), 'RAKUDO_MODULE_DEBUG'), 0);
sub DEBUG(*@strs) {
    my $err := nqp::getstderr();
    nqp::printfh($err, "MODULE_DEBUG: ");
    for @strs { nqp::printfh($err, $_) };
    nqp::printfh($err, "\n");
    1;
}

class Perl6::ModuleLoader does Perl6::ModuleLoaderVMConfig {
    my %modules_loaded;
    my %settings_loaded;
    my $absolute_path_func;

    my %language_module_loaders := nqp::hash(
        'NQP', nqp::gethllsym('nqp', 'ModuleLoader'),
    );

    method register_language_module_loader($lang, $loader) {
        nqp::die("Language loader already registered for $lang")
            if nqp::existskey(%language_module_loaders, $lang);
        %language_module_loaders{$lang} := $loader;
    }

    method register_absolute_path_func($func) {
        $absolute_path_func := $func;
    }

    method absolute_path($path) {
        $absolute_path_func ?? $absolute_path_func($path) !! $path;
    }

    method ctxsave() {
        $*MAIN_CTX := nqp::ctxcaller(nqp::ctx());
        $*CTXSAVE := 0;
    }

    method search_path() {
        # See if we have an @*INC set up, and if so just use that.
        my $PROCESS := nqp::gethllsym('perl6', 'PROCESS');
        if !nqp::isnull($PROCESS) {
            if !nqp::existskey($PROCESS.WHO, '@INC') {
                my &DYNAMIC :=
                  nqp::ctxlexpad(%settings_loaded{'CORE'})<&DYNAMIC>;
                if !nqp::isnull(&DYNAMIC) {
                    &DYNAMIC('@*INC');
                }
            }
            my $INC := ($PROCESS.WHO)<@INC>;
            if nqp::defined($INC) {
                my @INC := $INC.FLATTENABLE_LIST();
                if +@INC {
                    return @INC;
                }
            }
        }

        # Too early to have @*INC; probably no setting yet loaded to provide
        # the PROCESS initialization.
        my @search_paths;
        @search_paths.push('.');
        @search_paths.push('blib');
        for self.vm_search_paths() {
            @search_paths.push($_);
        }
        @search_paths
    }

    method load_module($module_name, %opts, *@GLOBALish, :$line, :$file, :%chosen) {
        unless %chosen {
            # See if we need to load it from elsewhere.
            if nqp::existskey(%opts, 'from') {
                if nqp::existskey(%language_module_loaders, %opts<from>) {
                    # We expect that custom module loaders will accept a Stash, only
                    # NQP expects a hash and therefor needs special handling.
                    if %opts<from> eq 'NQP' {
                        if +@GLOBALish {
                            my $target := nqp::knowhow().new_type(:name('GLOBALish'));
                            nqp::setwho($target, @GLOBALish[0].WHO.FLATTENABLE_HASH());
                            return %language_module_loaders<NQP>.load_module($module_name,
                                $target);
                        }
                        else {
                            return %language_module_loaders<NQP>.load_module($module_name);
                        }
                    }
                    if %opts<from> eq 'java' {
                        my $deprecated := $*W.find_symbol(['&DEPRECATED']);
                        nqp::call($deprecated, ':from<Java>', '2015.1', '2016.1', :what(':from<java>'));
                        return %language_module_loaders<Java>.load_module($module_name,
                            %opts, |@GLOBALish, :$line, :$file);
                    }
                    return %language_module_loaders{%opts<from>}.load_module($module_name,
                        %opts, |@GLOBALish, :$line, :$file);
                }
                else {
                    nqp::die("Do not know how to load code from " ~ %opts<from>);
                }
            }

            # Locate all the things that we potentially could load. Choose
            # the first one for now (XXX need to filter by version and auth).
            my @prefixes   := self.search_path();
            my @candidates := self.locate_candidates($module_name, @prefixes, :$file);
            if +@candidates == 0 {
                if nqp::defined($file) {
                    nqp::die("Could not find file '$file' for module $module_name");
                }
                else {
                    nqp::die("Could not find $module_name in any of: " ~
                        join(', ', @prefixes));
                }
            }
            %chosen := @candidates[0];
        }

        my @MODULES := nqp::clone(@*MODULES // []);
        for @MODULES -> $m {
            if $m<module> eq $module_name {
                nqp::die("Circular module loading detected involving module '$module_name'");
            }
        }
        unless nqp::ishash(%chosen) {
            %chosen := %chosen.FLATTENABLE_HASH();
        }
        if $DEBUG {
            for %chosen {
                say($_.key ~ ' => ' ~ $_.value);
            }
        }
        # If we didn't already do so, load the module and capture
        # its mainline. Otherwise, we already loaded it so go on
        # with what we already have.
        my $module_ctx;
        if nqp::defined(%modules_loaded{%chosen<key>}) {
            $module_ctx := %modules_loaded{%chosen<key>};
        }
        else {
            my @*MODULES := @MODULES;
            if +@*MODULES  == 0 {
                my %prev        := nqp::hash();
                %prev<line>     := $line;
                %prev<filename> := nqp::getlexdyn('$?FILES');
                @*MODULES[0]    := %prev;
            }
            else {
                @*MODULES[-1]<line> := $line;
            }
            my %trace := nqp::hash();
            %trace<module>   := $module_name;
            %trace<filename> := %chosen<pm>;
            my $preserve_global := nqp::ifnull(nqp::gethllsym('perl6', 'GLOBAL'), NQPMu);
            nqp::push(@*MODULES, %trace);
            if %chosen<load> {
                %trace<precompiled> := %chosen<load>;
                DEBUG("loading ", %chosen<load>) if $DEBUG;
                my %*COMPILING := {};
                my $*CTXSAVE := self;
                my $*MAIN_CTX;
                nqp::loadbytecode(%chosen<load>);
                %modules_loaded{%chosen<key>} := $module_ctx := $*MAIN_CTX;
                DEBUG("done loading ", %chosen<load>) if $DEBUG;
            }
            else {
                # If we're doing module pre-compilation, we should only
                # allow the modules we load to be pre-compiled also.
                my $precomp := 0;
                try $precomp := $*W.is_precompilation_mode();
                if $precomp {
                    nqp::die(
                        "When pre-compiling a module, its dependencies must be pre-compiled first.\n" ~
                        "Please pre-compile " ~ %chosen<pm>);
                }

                # Read source file.
                DEBUG("loading ", %chosen<pm>) if $DEBUG;
                my $fh := nqp::open(%chosen<pm>, 'r');
                nqp::setencoding($fh, 'utf8');
                my $source := nqp::readallfh($fh);
                nqp::closefh($fh);

                # Get the compiler and compile the code, then run it
                # (which runs the mainline and captures UNIT).
                my $?FILES   := %chosen<pm>;
                my $eval     := nqp::getcomp('perl6').compile($source);
                my $*CTXSAVE := self;
                my $*MAIN_CTX;
                $eval();
                %modules_loaded{%chosen<key>} := $module_ctx := $*MAIN_CTX;
                DEBUG("done loading ", %chosen<pm>) if $DEBUG;

            }
            nqp::bindhllsym('perl6', 'GLOBAL', $preserve_global);
            CATCH {
                nqp::bindhllsym('perl6', 'GLOBAL', $preserve_global);
                nqp::rethrow($_);
            }
        }

        # Provided we have a mainline and need to do global merging...
        if nqp::defined($module_ctx) {
            # Merge any globals.
            my $UNIT := nqp::ctxlexpad($module_ctx);
            if +@GLOBALish {
                unless nqp::isnull($UNIT<GLOBALish>) {
                    merge_globals(@GLOBALish[0], $UNIT<GLOBALish>);
                }
            }
            return $UNIT;
        }
        else {
            return {};
        }
    }

    # This is a first cut of the globals merger. For another approach,
    # see sorear++'s work in Niecza. That one is likely more "pure"
    # than this, but that would seem to involve copying too, and the
    # details of exactly what that entails are a bit hazy to me at the
    # moment. We'll see how far this takes us.
    my $stub_how := 'Perl6::Metamodel::PackageHOW';
    sub merge_globals($target, $source) {
        # Start off merging top-level symbols. Easy when there's no
        # overlap. Otherwise, we need to recurse.
        my %known_symbols;
        for stash_hash($target) {
            %known_symbols{$_.key} := 1;
        }
        for stash_hash($source) {
            my $sym := $_.key;
            if !%known_symbols{$sym} {
                ($target.WHO){$sym} := $_.value;
            }
            elsif ($target.WHO){$sym} =:= $_.value {
                # No problemo; a symbol can't conflict with itself.
            }
            else {
                my $source_mo := $_.value.HOW;
                my $source_is_stub := $source_mo.HOW.name($source_mo) eq $stub_how;
                my $target_mo := ($target.WHO){$sym}.HOW;
                my $target_is_stub := $target_mo.HOW.name($target_mo) eq $stub_how;
                if $source_is_stub && $target_is_stub {
                    # Both stubs. We can safely merge the symbols from
                    # the source into the target that's importing them.
                    merge_globals(($target.WHO){$sym}, $_.value);
                }
                elsif $source_is_stub {
                    # The target has a real package, but the source is a
                    # stub. Also fine to merge source symbols into target.
                    merge_globals(($target.WHO){$sym}, $_.value);
                }
                elsif $target_is_stub {
                    # The tricky case: here the interesting package is the
                    # one in the module. So we merge the other way around
                    # and install that as the result.
                    merge_globals($_.value, ($target.WHO){$sym});
                    ($target.WHO){$sym} := $_.value;
                }
                else {
                    nqp::die("Merging GLOBAL symbols failed: duplicate definition of symbol $sym");
                }
            }
        }
    }

    method load_setting($setting_name) {
        my $setting;

        if $setting_name ne 'NULL' {
            # Unless we already did so, locate and load the setting.
            unless nqp::defined(%settings_loaded{$setting_name}) {
                # Find it.
                my $path := self.find_setting($setting_name);

                # Load it.
                my $*CTXSAVE := self;
                my $*MAIN_CTX;
                my $preserve_global := nqp::ifnull(nqp::gethllsym('perl6', 'GLOBAL'), NQPMu);
                nqp::scwbdisable();
                nqp::loadbytecode($path);
                nqp::scwbenable();
                nqp::bindhllsym('perl6', 'GLOBAL', $preserve_global);
                unless nqp::defined($*MAIN_CTX) {
                    nqp::die("Unable to load setting $setting_name; maybe it is missing a YOU_ARE_HERE?");
                }
                %settings_loaded{$setting_name} := $*MAIN_CTX;
            }

            $setting := %settings_loaded{$setting_name};
        }

        return $setting;
    }

    # Handles any object repossession conflicts that occurred during module load,
    # or complains about any that cannot be resolved.
    method resolve_repossession_conflicts(@conflicts) {
        for @conflicts -> $orig, $current {
            # If it's a Stash in conflict, we make sure any original entries get
            # appropriately copied.
            if $orig.HOW.name($orig) eq 'Stash' {
                for $orig.FLATTENABLE_HASH() {
                    if !nqp::existskey($current, $_.key) || nqp::eqat($_.key, '&', 0) {
                        $current{$_.key} := $_.value;
                    }
                }
            }
            # We could complain about anything else, and may in the future; for
            # now, we let it pass by with "latest wins" semantics.
        }
    }

    sub stash_hash($pkg) {
        my $hash := $pkg.WHO;
        unless nqp::ishash($hash) {
            $hash := $hash.FLATTENABLE_HASH();
        }
        $hash
    }
}

nqp::bindhllsym('perl6', 'ModuleLoader', Perl6::ModuleLoader);
# From 'src/vm/jvm/Perl6/JavaModuleLoader.nqp'

class Perl6::JavaModuleLoader {
    my $interop;
    my $interop_loader;
    
    method set_interop_loader($loader) {
        $interop_loader := $loader;
    }
    
    method load_module($module_name, %opts, *@GLOBALish, :$line, :$file) {
        # Load interop support if needed.
        $interop := $interop_loader() unless nqp::isconcrete($interop);
        
        # Try to get hold of the type.
        my @parts := nqp::split('::', $module_name);
        my $jname := nqp::join('.', @parts);
        my $type  := $interop.typeForName($jname);
        if $type =:= NQPMu {
            nqp::die("Could not locate Java module $jname");
        }
        
        # Return unit-like thing with an EXPORT::DEFAULT.
        nqp::hash('EXPORT', make_package('EXPORT',
            nqp::hash('DEFAULT', make_package('DEFAULT',
                nqp::hash(@parts[nqp::elems(@parts) - 1], $type)))))
    }
    
    sub make_package($name, %who) {
        my $pkg := nqp::knowhow().new_type(:$name);
        $pkg.HOW.compose($pkg);
        nqp::setwho($pkg, %who);
        $pkg
    }
}

Perl6::ModuleLoader.register_language_module_loader('Java', Perl6::JavaModuleLoader);
Perl6::ModuleLoader.register_language_module_loader('java', Perl6::JavaModuleLoader);
nqp::bindhllsym('perl6', 'JavaModuleLoader', Perl6::JavaModuleLoader);

# vim: set ft=perl6 nomodifiable :

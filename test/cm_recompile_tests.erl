-module(cm_recompile_tests).

-compile([export_all]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("../src/ety_main.hrl").
-include_lib("../src/log.hrl").

% Parse a string such as "1+2" to return {ok, sets:from_list([1,2])}
-spec parse_versions(string()) -> {ok, sets:set(integer())} | error.
parse_versions(S) ->
    Comps = string:split(S, "+", all),
    try
        {ok, sets:from_list(lists:map(fun list_to_integer/1, Comps))}
    catch error:badarg:_ ->
        error
    end.

% Parse a filename such as "foo_V1+2.erl" to return {ok, "foo.erl", sets:from_list([1,2])}
-spec parse_filename(file:name()) -> {ok, string(), sets:set(integer())} | error.
parse_filename(Name) ->
    case filename:extension(Name) =:= ".erl" of
        false -> error;
        true ->
            Root = filename:rootname(Name),
            case string:split(Root, "_", trailing) of
                [Start, "V" ++ VersionsString] ->
                    case parse_versions(VersionsString) of
                        {ok, Versions} -> {ok, Start ++ ".erl", Versions};
                        error -> error
                    end;
                _ -> error
            end
    end.

% Look in the given directory for files of a certain version. For example, if the directory
% contains "foo_V1.erl" and "bar_V1+2.erl", and the version is 2, then the result is
% [{bar_V1+2.erl", "bar.erl"}]
-spec get_files_with_version(file:name(), integer()) -> [{file:name(), file:name()}].
get_files_with_version(Dir, Version) ->
    {ok, Files} = file:list_dir(Dir),
    lists:filtermap(
        fun(Filename) ->
            case parse_filename(Filename) of
                error -> false;
                {ok, Name, Versions} ->
                    case sets:is_element(Version, Versions) of
                        true -> {true, {Filename, Name}};
                        false -> false
                    end
            end
        end,
        Files).

-spec run_typechecker(file:name()) -> [file:name()].
run_typechecker(SrcDir) ->
    Opts = #opts{ files = [filename:join(SrcDir, "main.erl")], project_root = SrcDir },
    ety_main:doWork(Opts).

-spec test_recompile_version(file:name(), file:name(), integer(), [string()]) -> ok.
test_recompile_version(TargetDir, Dir, Version, ExpectedChanges) ->
    ?LOG_NOTE("Testing code version ~p in ~p", Version, Dir),
    % cleanup of previous source files
    {ok, ExistingFiles} = file:list_dir(TargetDir),
    lists:foreach(
        fun(F) ->
            case filename:extension(F) =:= ".erl" andalso filelib:is_regular(F) of
                true -> file:delete(F);
                false -> ok
            end
        end, ExistingFiles),
    % Copy new source files
    Files = get_files_with_version(Dir, Version),
    lists:foreach(fun({SrcFile,TargetFile}) ->
            From = filename:join(Dir, SrcFile),
            To = filename:join(TargetDir,TargetFile),
            ?LOG_INFO("Copying ~p to ~p", From, To),
            file:copy(From, To)
        end, Files),
    utils:mkdirs(filename:join(TargetDir, "_build/default/lib")),
    RealChanges = run_typechecker(TargetDir),
    ?assertEqual(lists:sort(ExpectedChanges),
        lists:sort(lists:map(fun filename:basename/1, RealChanges))),
    ?LOG_NOTE("Test successful for code version ~p in ~p", Version, Dir).

-spec test_recompile(file:name(), #{integer => [string()]}) -> ok.
test_recompile(Dir, VersionMap) ->
    Versions = lists:sort(maps:keys(VersionMap)),
    tmp:with_tmp_dir(Dir, "root", dont_delete,
        fun(TargetDir) ->
            lists:foreach(
                fun(V) ->
                    test_recompile_version(TargetDir, filename:join("test_files/recompilation/", Dir),
                        V, maps:get(V, VersionMap))
                end, Versions)
        end).

file_changes_test() ->
    test_recompile("file_changes", #{1 => ["bar.erl", "foo.erl", "main.erl"], 2 => ["foo.erl"]}),
    ok.

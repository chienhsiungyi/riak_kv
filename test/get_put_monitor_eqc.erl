-module(get_put_monitor_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(PUTS_ACTIVE, {riak_kv, node, puts, fsm, active}).
-define(GETS_ACTIVE, {riak_kv, node, gets, fsm, active}).
-define(PUTS_ERRORS, {riak_kv, node, puts, fsm, errors}).
-define(GETS_ERRORS, {riak_kv, node, gets, fsm, errors}).

-compile([export_all]).

-record(state, {
    get_fsm = [],
    put_fsm = [],
    get_errors = 0,
    put_errors = 0
}).

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

eqc_test_() ->
    {setup, fun() ->
                error_logger:tty(false),
                crypto:start(),
                ok
            end,
     fun(_) ->
             cleanup() 
     end, [
           {timeout, 360, ?_assertEqual(true, quickcheck(numtests(5000,
                           ?QC_OUT(prop()))))}
          ]}.

test() ->
    test(100).

test(N) ->
    quickcheck(numtests(N, prop())).

check() ->
    check(prop(), current_counterexample()).

prop() ->
    ?FORALL(Cmds, commands(?MODULE), begin
        reset_test_state(),
        {_,State,Res} = C = run_commands(?MODULE, Cmds),
        Prop = eqc_statem:pretty_commands(?MODULE, Cmds, C, 
            begin 
                    exit_gracefully(State), 
                    Res =:= ok 
            end),
        aggregate(command_names(Cmds), Prop)
    end).

%% wait for all fake fsms to finish, so the monitors
%% get to finish before folsom is stopped.
exit_gracefully(S) ->
    #state{put_fsm = PutList, get_fsm = GetList} = S,
    [end_and_wait(Pid, normal) || Pid <- PutList ++ GetList].

cleanup() ->
    crypto:stop(),
    error_logger:tty(true),
    application:stop(folsom),
    true.

reset_test_state() ->
    [maybe_stop_and_wait(Server) || Server <- [riak_core_stat_cache, riak_kv_stat]],
    application:stop(folsom),
    application:start(folsom),
    {ok, Cache} = riak_core_stat_cache:start_link(),
    {ok, Pid} = riak_kv_stat:start_link(),
    unlink(Pid),
    unlink(Cache).


%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================

initial_state() ->
    #state{}.

command(S) ->
    frequency([
        {3, {call, ?MODULE, put_fsm_started, []}},
        {3, {call, ?MODULE, get_fsm_started, []}},
        {1, {call, ?MODULE, put_fsm_noproc, []}},
        {1, {call, ?MODULE, get_fsm_noproc, []}},
        {1, {call, ?MODULE, put_fsm_exit_normal, [put, g_put_pid(S)]}},
        {1, {call, ?MODULE, put_fsm_exit_shutdown, [put, g_put_pid(S)]}},
        {1, {call, ?MODULE, put_fsm_exit_error, [put, g_put_pid(S)]}},
        {1, {call, ?MODULE, get_fsm_exit_normal, [get, g_get_pid(S)]}},
        {1, {call, ?MODULE, get_fsm_exit_shutdown, [get, g_get_pid(S)]}},
        {1, {call, ?MODULE, get_fsm_exit_error, [get, g_get_pid(S)]}}
    ]).

g_put_pid(#state{put_fsm = []}) ->
    undefined;
g_put_pid(#state{put_fsm = L}) ->
    oneof(L).

g_get_pid(#state{get_fsm = []}) ->
    undefined;
g_get_pid(#state{get_fsm = L}) ->
    oneof(L).

precondition(#state{get_fsm = []}, {call, _, _Command, [get, _]}) ->
    false;
precondition(#state{put_fsm = []}, {call, _, _Command, [put, _]}) ->
    false;
precondition(_,_) ->
    true.

next_state(S, Res, {call, _, get_fsm_started, []}) ->
    Gets2 = ordsets:add_element(Res, S#state.get_fsm),
    S#state{get_fsm = Gets2};

next_state(S, Res, {call, _, put_fsm_started, []}) ->
    Puts2 = ordsets:add_element(Res, S#state.put_fsm),
    S#state{put_fsm = Puts2};

next_state(S, _Res, {call, _, get_fsm_noproc, []}) ->
    S;

next_state(S, _Res, {call, _, put_fsm_noproc, []}) ->
    S;

next_state(S, _Res, {call, _, get_fsm_exit_error, [get, Pid]}) ->
    Gets2 = ordsets:del_element(Pid, S#state.get_fsm),
    ErrCount = S#state.get_errors + 1,
    S#state{get_fsm = Gets2, get_errors = ErrCount};

next_state(S, _Res, {call, _, _, [get, Pid]}) ->
    Gets2 = ordsets:del_element(Pid, S#state.get_fsm),
    S#state{get_fsm = Gets2};
    
next_state(S, _Res, {call, _, put_fsm_exit_error, [put, Pid]}) ->
    Puts2 = ordsets:del_element(Pid, S#state.put_fsm),
    ErrCount = S#state.put_errors + 1,
    S#state{put_fsm = Puts2, put_errors = ErrCount};

next_state(S, _Res, {call, _, _, [put, Pid]}) ->
    Puts2 = ordsets:del_element(Pid, S#state.put_fsm),
    S#state{put_fsm = Puts2}.

postcondition(_, _, _) ->
    true.

invariant(S) ->
    #state{put_errors = PutErrCount, get_errors = GetErrCount,
        put_fsm = PutList, get_fsm = GetList} = S,

    % with a timetrap of 60 seconds, the spiral will never have values slide off
    MetricExpects = [
        {?PUTS_ACTIVE, length(PutList)},
        {?GETS_ACTIVE, length(GetList)},
        {?PUTS_ERRORS, [{count, PutErrCount}, {one, PutErrCount}]},
        {?GETS_ERRORS, [{count, GetErrCount}, {one, GetErrCount}]}
    ],

    Zipped = [{Metric, Expected, folsom_metrics:get_metric_value(Metric)} ||
        {Metric, Expected} <- MetricExpects],
    Bad = [{Metric, {expected, Expected}, {actual, Actual}} || 
        {Metric, Expected, Actual} <- Zipped, Expected /= Actual],
    case Bad of
        [] -> true;
        _ -> Bad
    end.

poll_stat_change(Metric, OriginalValue) ->
    case folsom_metrics:get_metric_value(Metric) of
        OriginalValue -> 
            poll_stat_change(Metric, OriginalValue);
        _ ->
            ok
    end.

%% ====================================================================
%% Calls
%% ====================================================================

get_fsm_started() ->
    Pid = fake_fsm(),
    Original = folsom_metrics:get_metric_value(?GETS_ACTIVE),
    riak_kv_get_put_monitor:get_fsm_spawned(Pid),
    poll_stat_change(?GETS_ACTIVE, Original),
    Pid.

get_fsm_noproc() ->
    Pid = fake_fsm(),
    end_and_wait(Pid, normal),
    riak_kv_get_put_monitor:spawned(gets, Pid),
    Pid.

get_fsm_exit_normal(get, Pid) ->
    Original = folsom_metrics:get_metric_value(?GETS_ACTIVE),
    end_and_wait(Pid, normal),
    poll_stat_change(?GETS_ACTIVE, Original),
    Pid.

get_fsm_exit_shutdown(get, Pid) ->
    Original = folsom_metrics:get_metric_value(?GETS_ACTIVE),
    end_and_wait(Pid, shutdown),
    poll_stat_change(?GETS_ACTIVE, Original),
    Pid.

get_fsm_exit_error(get, Pid) ->
    OriginalActive = folsom_metrics:get_metric_value(?GETS_ACTIVE),
    OriginalErrors = folsom_metrics:get_metric_value(?GETS_ERRORS),
    end_and_wait(Pid, unnatural),
    poll_stat_change(?GETS_ACTIVE, OriginalActive),
    poll_stat_change(?GETS_ERRORS, OriginalErrors),
    Pid.

put_fsm_started() ->
    Original = folsom_metrics:get_metric_value(?PUTS_ACTIVE),
    Pid = fake_fsm(),
    riak_kv_get_put_monitor:put_fsm_spawned(Pid),
    poll_stat_change(?PUTS_ACTIVE, Original),
    Pid.

put_fsm_noproc() ->
    Pid = fake_fsm(),
    end_and_wait(Pid, normal),
    riak_kv_get_put_monitor:spawned(puts, Pid),
    Pid.

put_fsm_exit_normal(put, Pid) ->
    Original = folsom_metrics:get_metric_value(?PUTS_ACTIVE),
    end_and_wait(Pid, normal),
    poll_stat_change(?PUTS_ACTIVE, Original),
    Pid.

put_fsm_exit_shutdown(put, Pid) ->
    Original = folsom_metrics:get_metric_value(?PUTS_ACTIVE),
    end_and_wait(Pid, shutdown),
    poll_stat_change(?PUTS_ACTIVE, Original),
    Pid.

put_fsm_exit_error(put, Pid) ->
    OriginalActive = folsom_metrics:get_metric_value(?PUTS_ACTIVE),
    OriginalErrors = folsom_metrics:get_metric_value(?PUTS_ERRORS),
    end_and_wait(Pid, unnatural),
    poll_stat_change(?PUTS_ACTIVE, OriginalActive),
    poll_stat_change(?PUTS_ERRORS, OriginalErrors),
    Pid.

%% ====================================================================
%% Helpers
%% ====================================================================

fake_fsm() -> proc_lib:spawn(?MODULE, fake_fsm_loop, []).

fake_fsm_loop() ->
    receive
        ExitCause ->
            exit(ExitCause)
    end.

end_and_wait(Pid, Cause) ->
    Monref = erlang:monitor(process, Pid),
    Pid ! Cause,
    receive
        {'DOWN', Monref, process, Pid, _} ->
            ok
    end.

lists_random([]) ->
    erlang:error(badarg);
lists_random([E]) ->
    E;
lists_random(List) ->
    Max = length(List),
    Nth = crypto:rand_uniform(1, Max),
    lists:nth(Nth, List).

%% Make sure `Server' is not running
%% `Server' _MUST_ have an exported fun `stop/0'
%% that stopes the server
maybe_stop_and_wait(Server) ->
    case whereis(Server) of
        undefined ->
            ok;
        Pid ->
            Server:stop(),
            riak_kv_test_util:wait_for_pid(Pid)
    end.
-endif.

-module(valvex_queue_lifo_backend).

-behaviour(valvex_queue).
-behaviour(gen_server).

-export([ consume/5
        , is_locked/1
        , is_tombstoned/1
        , lock/1
        , pop/1
        , pop_r/1
        , push/2
        , push_r/2
        , size/1
        , start_consumer/1
        , start_link/2
        , tombstone/1
        ]).

-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , code_change/3
        , terminate/2
        ]).

%%==============================================================================
%% Queue Callbacks
%%==============================================================================
-spec start_link( valvex:valvex_ref()
                , valvex:valvex_queue()
                ) -> valvex:valvex_ref().
start_link(Valvex, Q) ->
  {ok, Pid} = gen_server:start_link(?MODULE, [Valvex, Q], []),
  Pid.

-spec pop(valvex:valvex_ref()) -> valvex:valvex_q_item().
pop(Q) ->
  gen_server:call(Q, pop).

-spec pop_r(valvex:valvex_ref()) -> valvex:valvex_q_item().
pop_r(Q) ->
  gen_server:call(Q, pop_r).

-spec push(valvex:valvex_ref(), valvex:valvex_q_item()) -> ok.
push(Q, Value) ->
  gen_server:cast(Q, {push, Value}).

-spec push_r(valvex:valvex_ref(), valvex:valvex_q_item()) -> ok.
push_r(Q, Value) ->
  gen_server:cast(Q, {push_r, Value}).

-spec tombstone(valvex:valvex_ref()) -> ok.
tombstone(Q) ->
  gen_server:cast(Q, tombstone).

-spec is_tombstoned(valvex:valvex_ref()) -> true | false.
is_tombstoned(Q) ->
  gen_server:call(Q, is_tombstoned).

-spec lock(valvex:valvex_ref()) -> ok.
lock(Q) ->
  gen_server:cast(Q, lock).

-spec is_locked(valvex:valvex_ref()) -> true | false.
is_locked(Q) ->
  gen_server:call(Q, is_locked).

-spec size(valvex:valvex_ref()) -> non_neg_integer().
size(Q) ->
  gen_server:call(Q, size).

-spec start_consumer(valvex:valvex_ref()) -> ok.
start_consumer(Q) ->
  gen_server:cast(Q, start_consumer).

-spec consume( valvex:valvex_ref()
             , valvex:valvex_ref()
             , valvex:queue_backend()
             , valvex:queue_key()
             , non_neg_integer()) -> ok.
consume(Valvex, QPid, Backend, Key, Timeout) ->
  do_consume(Valvex, QPid, Backend, Key, Timeout).

%%==============================================================================
%% Gen Server Callbacks
%%==============================================================================

init([ Valvex
     , { Key
       , {Threshold, unit}
       , {Timeout, seconds}
       , {Pushback, seconds}
       , _Backend
       }
     ]) ->
  {ok, #{ key        => Key
        , threshold  => Threshold
        , timeout    => Timeout
        , pushback   => Pushback
        , backend    => ?MODULE
        , size       => 0
        , queue      => queue:new()
        , locked     => true
        , tombstoned => false
        , valvex     => Valvex
        , queue_pid  => self()
        }}.

handle_call(pop, _From, #{ queue      := Q0
                         , size       := Size
                         , tombstoned := Tombstone
                         } = S) ->
  Value = queue:out_r(Q0),
  case Value of
    {{value, {_Work, _Reply, _Timestamp}}, Q} ->
      {reply, Value, update_state(Q, Size-1, S)};
    {empty, _}                                ->
      case Tombstone of
        false -> {reply, Value, S};
        true  -> {reply, {empty, tombstoned}, S}
      end
  end;
handle_call(pop_r, _From, #{ queue := Q0
                           , size  := Size
                           , tombstoned := Tombstone
                           } = S) ->
  Value = queue:out(Q0),
  case Value of
    {{value, {_Work, _Reply, _Timestamp}}, Q} ->
      {reply, Value, update_state(Q, Size-1, S)};
    {empty, _}                                ->
      case Tombstone of
        false -> {reply, Value, S};
        true  -> {reply, {empty, tombstoned}, S}
      end
  end;
handle_call(is_locked, _From, #{ locked := Locked } = S) ->
  {reply, Locked, S};
handle_call(is_tombstoned, _From, #{ tombstoned := Tombstoned } = S) ->
  {reply, Tombstoned, S};
handle_call(size, _From, #{ size := Size } = S) ->
  {reply, Size, S}.

handle_cast({push, {_Work, Reply, _Timestamp} = Value}, #{ key       := Key
                                                         , valvex    := Valvex
                                                         , queue     := Q
                                                         , threshold := Threshold
                                                         , size      := Size
                                                         , locked    := Locked
                                                         } = S) ->
  case Locked of
    true  -> {noreply, S};
    false ->
      case Size >= Threshold of
        true ->
          valvex:pushback(Valvex, Key, Reply),
          {noreply, S};
        false ->
          {noreply, update_state(queue:in(Value, Q), Size+1, S)}
      end
  end;
handle_cast( {push_r, {_Work, Reply, _Timestamp} = Value}, #{ key       := Key
                                                            , valvex    := Valvex
                                                            , queue     := Q
                                                            , threshold := Threshold
                                                            , size      := Size
                                                            , locked    := Locked
                                                            } = S) ->
  case Locked of
    true  -> {noreply, S};
    false ->
      case Size >= Threshold of
        true ->
          valvex:pushback(Valvex, Key, Reply),
          {noreply, S};
        false ->
          {noreply, update_state(queue:in_r(Value, Q), Size+1, S)}
      end
  end;
handle_cast(lock, S) ->
  {noreply, S#{ locked := true }};
handle_cast(tombstone, S) ->
  {noreply, S#{ tombstoned := true}};
handle_cast(start_consumer, #{ valvex    := Valvex
                             , queue_pid := QPid
                             , backend   := Backend
                             , key       := Key
                             , timeout   := Timeout
                             } = S) ->
  {ok, TRef} = timer:apply_interval( 100
                                   , ?MODULE
                                   , consume
                                   , [Valvex, QPid, Backend, Key, Timeout]
                                   ),
  {noreply, S#{ consumer => TRef
              , locked   := false
              }}.

handle_info(_Info, S) ->
  {noreply, S}.

code_change(_Vsn, S, _Extra) ->
  {ok, S}.

terminate(_Reason, #{ consumer := Consumer }) ->
  timer:cancel(Consumer).

%%%=============================================================================
%%% Helpers
%%%=============================================================================
do_consume(Valvex, QPid, Backend, Key, Timeout) ->
  try
    QueueValue = gen_server:call(QPid, pop),
    case QueueValue of
      {{value, {Work, Reply, Timestamp}}, _Q} ->
        case is_stale(Timeout, Timestamp) of
          false ->
            gen_server:call(Valvex, { assign_work
                                    , {Work, Reply, Timestamp}
                                    , {Key, QPid, Backend}
                                    }
                           );
          true  ->
            Reply ! {error, timeout}
        end,
        do_consume(Valvex, QPid, Backend, Key, Timeout);
      {empty, tombstoned} ->
        gen_server:call(Valvex, {remove, Key}),
        gen_server:stop(QPid);
      {empty, _} ->
        ok
    end
  catch _Error:_Reason ->
      do_consume(Valvex, QPid, Backend, Key, Timeout)
  end.

update_state(Q, Size, S) ->
  S#{ size := Size, queue := Q }.

is_stale(Timeout, Timestamp) ->
  TimeoutMS = timer:seconds(Timeout),
  Diff      = timer:now_diff(erlang:timestamp(), Timestamp),
  Diff > (TimeoutMS * 1000).
%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:

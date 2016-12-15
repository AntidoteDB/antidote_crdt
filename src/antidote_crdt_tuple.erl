%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc module antidote_crdt_tuple - An fixed size tuple
%%
%% This tuple is a container of other elements.
%% On create the number of elements, type and position of each element
%% are fixed and what follows are updates/resets on these elements
%% A tuple forwards all operations to the relative embedded CRDTs.
%% Deleting/removing an element of the tuple is not allowed, i.e. the tuple size id always fixed
%% Resetting the tuple means resetting all nested elements

-module(antidote_crdt_tuple).

-behaviour(antidote_crdt).

%% API
-export([new/0, new/1, value/1, update/2, equal/2,
  to_binary/1, from_binary/1, is_operation/1, downstream/2, require_state_downstream/1, is_bottom/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type state() :: [{{Position::integer(), Type::atom()}, NestedState::term()}].
-type op() ::
    {update, nested_op()}
  | {update, [nested_op()]}
  | {reset, {}}.
-type nested_op() :: {{Position::integer(), Type::atom()}, Op::term()}.
-type effect() ::
  Adds::[nested_downstream()].
-type nested_downstream() :: {{Position::integer(), Type::atom()}, {ok, Effect::term()}}.
-type value() :: [term()].

-spec new() -> state().
new() ->
  [].

new([H|T]) ->
  create(1, [H|T]).

create(_N, []) ->
  [];
create(N, [H|T]) ->
  [{{N, H}, H:new()}] ++ create(N+1, T).

-spec value(state()) -> value().
value(Tuple) ->
  [{Position, Type:value(State)} || {{Position, Type}, State} <- Tuple].

-spec require_state_downstream(op()) -> boolean().
require_state_downstream(_Op) ->
  true.

-spec downstream(op(), state()) -> {ok, effect()}.
downstream({update, {{Position, Type}, Op}}, CurrentTuple) ->
  downstream({update, [{{Position, Type}, Op}]}, CurrentTuple);
downstream({update, NestedOps}, CurrentTuple) ->
  UpdateEffects = [generate_downstream_update(Op, CurrentTuple) || Op <- NestedOps],
  {ok, UpdateEffects};
downstream({reset, {}} = Op, CurrentTuple) ->
  % reset all nested
  NestedOps = [{{Position, Type}, Op} || {{Position, Type}, _Val} <- CurrentTuple],
  downstream({update, NestedOps}, CurrentTuple).

-spec generate_downstream_update(nested_op(), state()) -> nested_downstream().
generate_downstream_update({{Position, Type}, Op}, CurrentTuple) ->
  {_, CurrentState} = lists:nth(Position, CurrentTuple),
  {ok, DownstreamEffect} = Type:downstream(Op, CurrentState),
  {{Position, Type}, {ok, DownstreamEffect}}.

-spec update(effect(), state()) -> {ok, state()}.
update(Updates, State) ->
  State2 = lists:foldl(fun(E, S) -> update_entry(E, S)  end, State, Updates),
  {ok, State2}.

update_entry({{Position, Type}, {ok, Op}}, Tuple) ->
  {_, State} = lists:nth(Position, Tuple),
  {ok, UpdatedState} = Type:update(Op, State),
  lists:keyreplace({Position, Type}, 1, Tuple, {{Position, Type}, UpdatedState}).

equal(Tuple1, Tuple2) ->
    Tuple1 == Tuple2. % TODO better implementation (recursive equals)

-define(TAG, 101).
-define(V1_VERS, 1).

to_binary(Policy) ->
    <<?TAG:8/integer, ?V1_VERS:8/integer, (term_to_binary(Policy))/binary>>.

from_binary(<<?TAG:8/integer, ?V1_VERS:8/integer, Bin/binary>>) ->
  {ok, binary_to_term(Bin)}.

is_operation(Operation) ->
  case Operation of
    {update, {{_Position, Type}, Op}} ->
      antidote_crdt:is_type(Type)
        andalso Type:is_operation(Op);
    {update, Ops} when is_list(Ops) ->
      distinct([Position || {Position, _} <- Ops])
      andalso lists:all(fun(Op) -> is_operation({update, Op}) end, Ops);
    {reset, {}} -> true;
    _ ->
      false
  end.

distinct([]) -> true;
distinct([X|Xs]) ->
  not lists:member(X, Xs) andalso distinct(Xs).

is_bottom(Tuple) ->
  Bottom = fun({{_, T}, S}) -> erlang:function_exported(T, is_bottom, 1) andalso T:is_bottom(S) end,
  lists:all(Bottom, Tuple).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

reset1_test() ->
  Tuple0 = new([antidote_crdt_fat_counter, antidote_crdt_set_rw]),
  io:format("Tuple0 = ~p~n", [Tuple0]),
  % DC1: a.incr
  {ok, Incr1} = downstream({update, {{1, antidote_crdt_fat_counter}, {increment, 1}}}, Tuple0),
  io:format("Incr1 = ~p~n", [Incr1]),
  {ok, Tuple1a} = update(Incr1, Tuple0),
  io:format("Tuple1a = ~p~n", [Tuple1a]),
  % DC1 reset
  {ok, Reset1} = downstream({reset, {}}, Tuple1a),
  {ok, Tuple1b} = update(Reset1, Tuple1a),
  % DC2 a.remove
  {ok, Add1} = downstream({update, {{2, antidote_crdt_set_rw}, {add, a}}}, Tuple0),
  {ok, Tuple2a} = update(Add1, Tuple0),
  % DC2 --> DC1
  {ok, Tuple1c} = update(Add1, Tuple1b),
  % DC1 reset
  {ok, Reset2} = downstream({reset, {}}, Tuple1c),
  {ok, Tuple1d} = update(Reset2, Tuple1c),
  % DC1: a.incr
  {ok, Incr2} = downstream({update, {{1, antidote_crdt_fat_counter}, {increment, 2}}}, Tuple1d),
  {ok, Tuple1e} = update(Incr2, Tuple1d),

  ?assertEqual([{1, 0}, {2, []}], value(Tuple0)),
  ?assertEqual([{1, 1}, {2, []}], value(Tuple1a)),
  ?assertEqual([{1, 0}, {2, []}], value(Tuple1b)),
  ?assertEqual([{1, 0}, {2, [a]}], value(Tuple2a)),
  ?assertEqual([{1, 0}, {2, [a]}], value(Tuple1c)),
  ?assertEqual([{1, 0}, {2, []}], value(Tuple1d)),
  ?assertEqual([{1, 2}, {2, []}], value(Tuple1e)).

-endif.

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

%% @doc module antidote_crdt_gset - An operation based grow-only set

-module(antidote_crdt_gset).

-behaviour(antidote_crdt).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([ new/0,
          value/1,
          downstream/2,
          update/2,
          equal/2,
          to_binary/1,
          from_binary/1,
          is_operation/1,
          require_state_downstream/1,
          can_compress/2,
          compress/2
        ]).

-type gset() :: ordsets:ordset(member()).
-type gset_op() :: {add, member()}
                 | {add_all, [member()]}.

-type gset_effect() :: gset().
-type member() :: term().

new() ->
    ordsets:new().

value(Set) ->
    Set.

-spec downstream(gset_op(), gset()) -> {ok, gset_effect()}.
downstream({add, Elem}, _State) ->
  {ok, ordsets:from_list([Elem])};
downstream({add_all, Elems}, _State) ->
  {ok, ordsets:from_list(Elems)}.

update(Effect, State) ->
  {ok, ordsets:union(State, Effect)}.

require_state_downstream(_Operation) -> false.

is_operation({add, _}) -> true;
is_operation({add_all, _}) -> true;
is_operation(_) -> false.

equal(CRDT1, CRDT2) ->
    CRDT1 == CRDT2.

to_binary(CRDT) ->
    erlang:term_to_binary(CRDT).

from_binary(Bin) ->
  {ok, erlang:binary_to_term(Bin)}.

%% ===================================================================
%% Compression functions
%% ===================================================================

-spec can_compress(gset_effect(), gset_effect()) -> boolean().
can_compress(_, _) -> true.

-spec compress(gset_effect(), gset_effect()) -> {gset_effect() | noop, gset_effect() | noop}.
compress([], []) -> {noop, []};
compress(A, []) -> {noop, A};
compress([], B) -> {noop, B};
compress(A, B) -> {noop, ordsets:union(A, B)}.

%% ===================================================================
%% EUnit tests
%% ===================================================================

-ifdef(test).
all_test() ->
    S0 = new(),
    {ok, Downstream} = downstream({add, a}, S0),
    {ok, S1} = update(Downstream, S0),
    ?assertEqual(1, riak_dt_gset:stat(element_count, S1)).

compression_test() ->
    ?assertEqual(can_compress([1, 2, 3], [4, 5, 6]), true),
    ?assertEqual(compress([1, 2, 3], [4, 5, 6]), {noop, [1, 2, 3, 4, 5, 6]}),
    ?assertEqual(compress([1, 2, 3], []), {noop, [1, 2, 3]}),
    ?assertEqual(compress([], [4, 5, 6]), {noop, [4, 5, 6]}).

-endif.

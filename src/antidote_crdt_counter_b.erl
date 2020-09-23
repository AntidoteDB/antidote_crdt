%% -------------------------------------------------------------------
%%
%% Copyright <2013-2018> <
%%  Technische Universität Kaiserslautern, Germany
%%  Université Pierre et Marie Curie / Sorbonne-Université, France
%%  Universidade NOVA de Lisboa, Portugal
%%  Université catholique de Louvain (UCL), Belgique
%%  INESC TEC, Portugal
%% >
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
%% KIND, either expressed or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% List of the contributors to the development of Antidote: see AUTHORS file.
%% Description and complete License: see LICENSE file.

%% @doc
%% An operation based implementation of the bounded counter CRDT.
%% This counter is able to maintain a non-negative value by
%% explicitly exchanging permissions to execute decrement operations.
%% All operations on this CRDT are monotonic and do not keep extra tombstones.
%% In the code the variable V is used for permissions which a positive integer.
%% The number of total permissions can be 0 but can never be less than 0.
%% In the code the variable P is used for transfers() which is a defined type.
%% In the code the variable D is used for decrements() which is a defined type.
%% @end

-module(antidote_crdt_counter_b).

-behaviour(antidote_crdt).

-include("antidote_crdt.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% Call backs
-export([new/0,
    value/1,
    downstream/2,
    update/2,
    equal/2,
    to_binary/1,
    from_binary/1,
    is_operation/1,
    require_state_downstream/1,
    generate_downstream_check/4
]).

%% API
-export([localPermissions/2,
    local_permissions/2,
    permissions/1
]).

%% A replica's identifier.
-type id() :: term().
%% An orddict that contains permission transfers from one id to the other id. The two ids can be equal which is the representation of an increment.
-type transfers() :: orddict:orddict({id(), id()}, pos_integer()).
%% An orddict that contains the decrements that were performed on an id.
-type decrements() :: orddict:orddict(id(), pos_integer()).
-type antidote_crdt_counter_b() :: {transfers(), decrements()}.
-type antidote_crdt_counter_b_op() :: antidote_crdt_counter_b_partial_op() | antidote_crdt_counter_b_full_op().
-type antidote_crdt_counter_b_full_op() :: {increment, {pos_integer(), id()}} | {decrement, {pos_integer(), id()}} | {transfer, {pos_integer(), id(), id()}}.
-type antidote_crdt_counter_b_partial_op() :: {increment, pos_integer()} | {decrement, pos_integer()} | {transfer, {pos_integer(), id()}}.
-type antidote_crdt_counter_b_effect() :: {{increment, pos_integer()}, id()} | {{decrement, pos_integer()}, id()} | {{transfer, pos_integer(), id()}, id()}.

%% @doc Return a new, empty `antidote_crdt_counter_b()'.
-spec new() -> antidote_crdt_counter_b().
new() ->
    {orddict:new(), orddict:new()}.

%% Kept for backwards compatibility.
-spec localPermissions(id(), antidote_crdt_counter_b()) -> non_neg_integer().
localPermissions(Id, {P, D}) ->
    local_permissions(Id, {P, D}).

%% @doc Return the available permissions of replica `Id' in a `antidote_crdt_counter_b()'.
-spec local_permissions(id(), antidote_crdt_counter_b()) -> non_neg_integer().
local_permissions(Id, {P, D}) ->
    Received = orddict:fold(
        fun
            (_, V, Acc) ->
                Acc + V
        end,
        0, orddict:filter(
            fun
                ({_, ToId}, _) when ToId == Id ->
                    true;
                (_, _) ->
                    false
            end, P)),
    Granted = orddict:fold(
        fun
            (_, V, Acc) ->
                Acc + V
        end, 0, orddict:filter(
            fun
                ({FromId, ToId}, _) when FromId == Id andalso ToId /= Id ->
                    true;
                (_, _) ->
                    false
            end, P)),
    case orddict:find(Id, D) of
        {ok, Decrements} ->
            Received - Granted - Decrements;
        error ->
            Received - Granted
    end.

%% @doc Return the total available permissions in a `antidote_crdt_counter_b()'.
-spec permissions(antidote_crdt_counter_b()) -> non_neg_integer().
permissions({P, D}) ->
    TotalIncrements = orddict:fold(
        fun
            ({K, K}, V, Acc) ->
                V + Acc;
            (_, _, Acc) ->
                Acc
        end, 0, P),
    TotalDecrements = orddict:fold(
        fun
            (_, V, Acc) ->
                V + Acc
        end, 0, D),
    TotalIncrements - TotalDecrements.

%% @doc Return the read value of a given `antidote_crdt_counter_b()', itself.
-spec value(antidote_crdt_counter_b()) -> antidote_crdt_counter_b().
value(Counter) -> Counter.

%% @doc Generate a downstream operation.
%% The first parameter is either `{increment, pos_integer()}' or `{decrement, pos_integer()}',
%% which specify the operation and amount, or `{transfer, pos_integer(), id()}'
%% that additionally specifies the target replica.
%% The second parameter is an id() who identifies the source replica,
%% and the third parameter is a `antidote_crdt_counter_b()' which holds the current snapshot.
%%
%% Return a tuple containing the operation and source replica.
%% This operation fails and returns `{error, no_permissions}'
%% if it tries to consume resources unavailable to the source replica
%% (which prevents logging of forbidden attempts).
%% IMPORTANT: The operation is not checked for correctness here!
%% Using an operation that does not pass the is_operation() check can return invalid results and if applied can break the permissions of the antidote_crdt_counter_b!
-spec downstream(antidote_crdt_counter_b_op(), antidote_crdt_counter_b()) -> {ok, antidote_crdt_counter_b_effect()} | {error, no_permissions}.
downstream({increment, {V, Id}}, _Counter) ->
    {ok, {{increment, V}, Id}};
downstream({decrement, {V, Id}}, Counter) ->
    generate_downstream_check({decrement, V}, Id, Counter, V);
downstream({transfer, {V, ToId, FromId}}, Counter) ->
    generate_downstream_check({transfer, V, ToId}, FromId, Counter, V);
%%Special case if the client uses an update without ids
downstream({_, _}, _) ->
    {error, no_permissions}.

-spec generate_downstream_check({decrement, pos_integer()} | {transfer, pos_integer(), id()}, id(), antidote_crdt_counter_b(), pos_integer()) -> {ok, antidote_crdt_counter_b_effect()} | {error, no_permissions}.
generate_downstream_check(PartialEffect, Id, Counter, V) ->
    Available = local_permissions(Id, Counter),
    if Available >= V -> {ok, {PartialEffect, Id}};
        Available < V -> {error, no_permissions}
    end.

%% @doc Update a `antidote_crdt_counter_b()' with a downstream operation,
%% usually created with `generate_downstream'.
%%
%% Return the resulting `antidote_crdt_counter_b()' after applying the operation.
%% IMPORTANT: The downstream effect is not checked for correctness here!
%% Using a downstream effect that is invalid can break the permissions of the antidote_crdt_counter_b!
-spec update(antidote_crdt_counter_b_effect(), antidote_crdt_counter_b()) -> {ok, antidote_crdt_counter_b()}.
update({{increment, V}, Id}, Counter) ->
    increment(Id, V, Counter);
update({{decrement, V}, Id}, Counter) ->
    decrement(Id, V, Counter);
update({{transfer, V, ToId}, FromId}, Counter) ->
    transfer(FromId, ToId, V, Counter).

%% Add a given amount of permissions to a replica.
-spec increment(id(), pos_integer(), antidote_crdt_counter_b()) -> {ok, antidote_crdt_counter_b()}.
increment(Id, V, {P, D}) ->
    {ok, {orddict:update_counter({Id, Id}, V, P), D}}.

%% Consume a given amount of permissions from a replica.
-spec decrement(id(), pos_integer(), antidote_crdt_counter_b()) -> {ok, antidote_crdt_counter_b()}.
decrement(Id, V, {P, D}) ->
    {ok, {P, orddict:update_counter(Id, V, D)}}.

%% Transfer a given amount of permissions from one replica to another.
-spec transfer(id(), id(), pos_integer(), antidote_crdt_counter_b()) -> {ok, antidote_crdt_counter_b()}.
transfer(FromId, ToId, V, {P, D}) ->
    {ok, {orddict:update_counter({FromId, ToId}, V, P), D}}.

%% doc Return the binary representation of a `antidote_crdt_counter_b()'.
-spec to_binary(antidote_crdt_counter_b()) -> binary().
to_binary(C) -> term_to_binary(C).

%% doc Return a `antidote_crdt_counter_b()' from its binary representation.
-spec from_binary(binary()) -> {ok, antidote_crdt_counter_b()}.
from_binary(<<B/binary>>) -> {ok, binary_to_term(B)}.

%% @doc The following operation verifies
%%      that Operation is supported by this particular CRDT.
-spec is_operation(term()) -> boolean().
is_operation({increment, {V, _Id}}) -> is_pos_integer(V);
is_operation({decrement, {V, _Id}}) -> is_pos_integer(V);
is_operation({transfer, {V, _ToId, _FromId}}) -> is_pos_integer(V);
is_operation({increment, V}) -> is_pos_integer(V);
is_operation({decrement, V}) -> is_pos_integer(V);
is_operation({transfer, {V, _ToId}}) -> is_pos_integer(V);
is_operation(_) -> false.

-spec is_pos_integer(term()) -> boolean().
is_pos_integer(V) -> is_integer(V) andalso (V > 0).

%% The antidote_crdt_counter_b requires no state downstream for increment.
-spec require_state_downstream(antidote_crdt_counter_b_op()) -> boolean().
require_state_downstream({increment, _}) ->
    false;
require_state_downstream(_) ->
    true.

%% Checks equality.
%% Since all contents of the antidote_crdt_counter_b are ordered (two orddicts)
%% they will be equal if the content is equal.
-spec equal(antidote_crdt_counter_b(), antidote_crdt_counter_b()) -> boolean().
equal(BCounter1, BCounter2) ->
    BCounter1 == BCounter2.

%% ===================================================================
%% EUnit tests
%% ===================================================================

-ifdef(TEST).

%% Utility to generate and apply downstream operations.
apply_op(Op, Counter) ->
    {ok, OP_DS} = downstream(Op, Counter),
    {ok, NewCounter} = update(OP_DS, Counter),
    NewCounter.

%% Tests creating a new `antidote_crdt_counter_b()'.
new_test() ->
    ?assertEqual({orddict:new(), orddict:new()}, new()).

%% Tests increment operations.
increment_test() ->
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    Counter2 = apply_op({increment, {5, r2}}, Counter1),
    %% Test replicas' values.
    ?assertEqual(5, local_permissions(r2, Counter2)),
    ?assertEqual(10, local_permissions(r1, Counter2)),
    %% Test total value.
    ?assertEqual(15, permissions(Counter2)).

%% Tests the function `local_permissions()'.
local_permissions_test() ->
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    %% Test replica with positive amount of permissions.
    ?assertEqual(10, local_permissions(r1, Counter1)),
    %% Test nonexistent replica.
    ?assertEqual(0, local_permissions(r2, Counter1)),
    ?assertEqual(10, permissions(Counter1)).

%% Tests decrement operations.
decrement_test() ->
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    %% Test allowed decrement.
    Counter2 = apply_op({decrement, {6, r1}}, Counter1),
    ?assertEqual(4, permissions(Counter2)),
    %% Test nonexistent replica.
    ?assertEqual(0, local_permissions(r2, Counter1)),
    ?assertEqual(0, local_permissions(r2, Counter2)),
    %% Test forbidden decrement.
    OP_DS = downstream({decrement, {6, r1}}, Counter2),
    ?assertEqual({error, no_permissions}, OP_DS).

%% Tests a more complex chain of increment and decrement operations.
decrement_increment_test() ->
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    Counter2 = apply_op({decrement, {6, r1}}, Counter1),
    Counter3 = apply_op({increment, {6, r2}}, Counter2),
    %% Test several replicas (balance each other).
    ?assertEqual(10, permissions(Counter3)),
    %% Test forbidden permissions, when total is higher than consumed.
    OP_DS = downstream({decrement, {6, r1}}, Counter3),
    ?assertEqual({error, no_permissions}, OP_DS),
    %% Test the same operation is allowed on another replica with enough permissions.
    Counter4 = apply_op({decrement, {6, r2}}, Counter3),
    ?assertEqual(4, permissions(Counter4)).

%% Tests transferring permissions.
transfer_test() ->
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    %% Test transferring permissions from one replica to another.
    Counter2 = apply_op({transfer, {6, r2, r1}}, Counter1),
    ?assertEqual(4, local_permissions(r1, Counter2)),
    ?assertEqual(6, local_permissions(r2, Counter2)),
    ?assertEqual(10, permissions(Counter2)),
    %% Test transference forbidden by lack of previously transferred resources.
    OP_DS = downstream({transfer, {5, r2, r1}}, Counter2),
    ?assertEqual({error, no_permissions}, OP_DS),
    %% Test transference enabled by previously transferred resources.
    Counter3 = apply_op({transfer, {5, r1, r2}}, Counter2),
    ?assertEqual(9, local_permissions(r1, Counter3)),
    ?assertEqual(1, local_permissions(r2, Counter3)),
    ?assertEqual(10, permissions(Counter3)).

operation_without_id_test() ->
    Counter0 = new(),
    IncrementOp = {increment, 5},
    DecrementOp = {decrement, 5},
    TransferOp = {transfer, {5, dcid}},
    ?assertEqual(true, is_operation(IncrementOp)),
    ?assertEqual(true, is_operation(DecrementOp)),
    ?assertEqual(true, is_operation(TransferOp)),
    ?assertEqual({error, no_permissions}, downstream(IncrementOp, Counter0)),
    ?assertEqual({error, no_permissions}, downstream(DecrementOp, Counter0)),
    ?assertEqual({error, no_permissions}, downstream(TransferOp, Counter0)).

%% Tests the function `value()'.
value_test() ->
    %% Test on `antidote_crdt_counter_b()' resulting from applying all kinds of operation.
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    Counter2 = apply_op({decrement, {6, r1}}, Counter1),
    Counter3 = apply_op({transfer, {2, r2, r1}}, Counter2),
    %% Assert `value()' returns `antidote_crdt_counter_b()' itself.
    ?assertEqual(Counter3, value(Counter3)).

transfer_to_self_is_is_not_allowed_if_not_enough_local_permissions_exist_test() ->
    Counter0 = new(),
    Counter1 = apply_op({increment, {8, r1}}, Counter0),
    DownstreamResult = downstream({transfer, {10, r1, r1}}, Counter1),
    ?assertEqual({error, no_permissions}, DownstreamResult).

transfer_to_self_is_increment_if_enough_local_permissions_exist_test() ->
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    Counter2 = apply_op({increment, {10, r1}}, Counter0),
    Counter3 = apply_op({increment, {10, r1}}, Counter1),
    Counter4 = apply_op({transfer, {10, r1, r1}}, Counter2),
    ?assertEqual(Counter3, Counter4).

%% Tests serialization functions `to_binary()' and `from_binary()'.
binary_test() ->
    %% Test on `antidote_crdt_counter_b()' resulting from applying all kinds of operation.
    Counter0 = new(),
    Counter1 = apply_op({increment, {10, r1}}, Counter0),
    Counter2 = apply_op({decrement, {6, r1}}, Counter1),
    Counter3 = apply_op({transfer, {2, r2, r1}}, Counter2),
    %% Assert marshalling and unmarshalling holds the same `antidote_crdt_counter_b()'.
    B = to_binary(Counter3),
    ?assertEqual({ok, Counter3}, from_binary(B)).

%% Tests that operations are correctly detected.
is_operation_test() ->
    ?assertEqual(true, is_operation({transfer, {2, r2, r1}})),
    ?assertEqual(false, is_operation({transfer, {-2, r2, r1}})),
    ?assertEqual(false, is_operation({transfer, {0, r2, r1}})),
    ?assertEqual(true, is_operation({transfer, {2, r2}})),
    ?assertEqual(false, is_operation({transfer, {-2, r2}})),
    ?assertEqual(false, is_operation({transfer, 2})),
    ?assertEqual(true, is_operation({increment, {50, r1}})),
    ?assertEqual(false, is_operation({increment, {-50, r1}})),
    ?assertEqual(true, is_operation({increment, 50})),
    ?assertEqual(false, is_operation({increment, -50})),
    ?assertEqual(false, is_operation(increment)),
    ?assertEqual(true, is_operation({decrement, {50, r1}})),
    ?assertEqual(true, is_operation({decrement, 50})),
    ?assertEqual(false, is_operation(decrement)),
    ?assertEqual(false, is_operation({anything, [1, 2, 3]})).

%% Tests that operations are only valid with a positive integer.
is_operation_only_pos_integer_test() ->
    ?assertEqual(true, is_operation({increment, {1, r1}})),
    ?assertEqual(false, is_operation({increment, {0, r1}})),
    ?assertEqual(false, is_operation({increment, {-1, r1}})),
    ?assertEqual(true, is_operation({increment, 1})),
    ?assertEqual(false, is_operation({increment, 0})),
    ?assertEqual(false, is_operation({increment, -1})),

    ?assertEqual(true, is_operation({decrement, {1, r1}})),
    ?assertEqual(false, is_operation({decrement, {0, r1}})),
    ?assertEqual(false, is_operation({decrement, {-1, r1}})),
    ?assertEqual(true, is_operation({decrement, 1})),
    ?assertEqual(false, is_operation({decrement, 0})),
    ?assertEqual(false, is_operation({decrement, -1})),

    ?assertEqual(true, is_operation({transfer, {1, r2, r1}})),
    ?assertEqual(false, is_operation({transfer, {0, r2, r1}})),
    ?assertEqual(false, is_operation({transfer, {-1, r2, r1}})),
    ?assertEqual(true, is_operation({transfer, {1, r2}})),
    ?assertEqual(false, is_operation({transfer, {0, r2}})),
    ?assertEqual(false, is_operation({transfer, {-1, r2}})).

-endif.

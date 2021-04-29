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
%% -------------------------------------------------------------------

-module(prop_counter_b).

-define(PROPER_NO_TRANS, true).
-include_lib("proper/include/proper.hrl").

%% API
-export([prop_is_operation/0,
    prop_is_not_operation/0,
    prop_partial_operations_cannot_create_downstream_operations/0,
    prop_increment_decrement/0,
    prop_multiple_operations_check_with_two_possible_ids/0]).


%%%%%%%%%%%%%%%%%%
%%% Properties %%%
%%%%%%%%%%%%%%%%%%

%% Simple check that valid operations are valid.
prop_is_operation() ->
    ?FORALL(Operation, valid_operations(),
        begin
            antidote_crdt_counter_b:is_operation(Operation)
        end).

%% Simple check that negative operations are no valid operations.
prop_is_not_operation() ->
    ?FORALL(Operation, invalid_negative_operations(),
        begin
            not antidote_crdt_counter_b:is_operation(Operation)
        end).

prop_partial_operations_cannot_create_downstream_operations() ->
    ?FORALL(Operation, valid_partial_operations(),
        begin
            true = antidote_crdt_counter_b:is_operation(Operation),
            {error, no_permissions} == antidote_crdt_counter_b:downstream(Operation, antidote_crdt_counter_b:new())
        end).

%% This test checks that increment and decrement operation work correctly when performed after each other.
%% If the increment is larger than or equal to the decrement then the both operations work correctly and the total permissions are calculated correctly.
%% If the increment is smaller than the decrement then the increment works but the decrement returns {error, no_permissions}.
prop_increment_decrement() ->
    proper:forall(get_increment_decrement_ops(),
        fun(OpType) ->
            {IncrementOp = {increment, {IncrementValue, undefined}}, DecrementOp = {decrement, {DecrementValue, undefined}}} = OpType,
            Counter1 = antidote_crdt_counter_b:new(),
            true = antidote_crdt_counter_b:is_operation(IncrementOp),
            true = antidote_crdt_counter_b:is_operation(DecrementOp),
            {error, no_permissions} = antidote_crdt_counter_b:downstream(DecrementOp, Counter1),
            {ok, IncrementEffect} = antidote_crdt_counter_b:downstream(IncrementOp, Counter1),
            {ok, Counter2} = antidote_crdt_counter_b:update(IncrementEffect, Counter1),
            DecrementEffectResult = antidote_crdt_counter_b:downstream(DecrementOp, Counter2),
            case IncrementValue >= DecrementValue of
                true ->
                    {ok, DecrementEffect} = DecrementEffectResult,
                    {ok, Counter3} = antidote_crdt_counter_b:update(DecrementEffect, Counter2),
                    CorrectPermissions = IncrementValue - DecrementValue,
                    TotalPermissions = antidote_crdt_counter_b:permissions(Counter3),
                    LocalPermissions = antidote_crdt_counter_b:local_permissions(undefined, Counter3),
                    true = CorrectPermissions == TotalPermissions,
                    true = TotalPermissions == LocalPermissions;
                false ->
                    {error, no_permissions} == DecrementEffectResult
            end
        end).

%% This is currently the most extensive check and takes a list of random operations and applies them.
%% All operations are checked extensively using the helper functions.
prop_multiple_operations_check_with_two_possible_ids() ->
    proper:forall(get_random_ops_with_two_possible_ids(),
        fun(Ops) ->
            lists:foldl(
                fun(CurrentOp, CurrentBCounter) ->
                    apply_op_and_check(CurrentOp, CurrentBCounter)
                end, antidote_crdt_counter_b:new(), Ops),
            true
        end).

%%%%%%%%%%%%%%%
%%% Helpers %%%
%%%%%%%%%%%%%%%

-spec apply_op_and_check(antidote_crdt_counter_b:antidote_crdt_counter_b_full_op(), antidote_crdt_counter_b:antidote_crdt_counter_b()) -> antidote_crdt_counter_b:antidote_crdt_counter_b().
apply_op_and_check(CurrentOp, CurrentBCounter) ->
    true = antidote_crdt_counter_b:is_operation(CurrentOp),
    DownstreamResult = antidote_crdt_counter_b:downstream(CurrentOp, CurrentBCounter),
    case CurrentOp of
        {increment, {V, Id}} ->
            {ok, Downstream = {{increment, V}, Id}} = DownstreamResult,
            {ok, NewBCounter} = antidote_crdt_counter_b:update(Downstream, CurrentBCounter),
            permissions_increment_check(Id, V, CurrentBCounter, NewBCounter);
        {decrement, {V, Id}} ->
            LocalPermissions = antidote_crdt_counter_b:local_permissions(Id, CurrentBCounter),
            case LocalPermissions >= V of
                true ->
                    {ok, Downstream = {{decrement, V}, Id}} = DownstreamResult,
                    {ok, NewBCounter} = antidote_crdt_counter_b:update(Downstream, CurrentBCounter),
                    permissions_decrement_check(Id, V, CurrentBCounter, NewBCounter);
                false ->
                    {error, no_permissions} = DownstreamResult,
                    CurrentBCounter
            end;
        {transfer, {V, _ToId, FromId}} ->
            LocalPermissions = antidote_crdt_counter_b:local_permissions(FromId, CurrentBCounter),
            case LocalPermissions >= V of
                true ->
                    {ok, Downstream = {{transfer, V, ToId}, FromId}} = DownstreamResult,
                    {ok, NewBCounter} = antidote_crdt_counter_b:update(Downstream, CurrentBCounter),
                    permissions_transfer_check(ToId, FromId, V, CurrentBCounter, NewBCounter);
                false ->
                    {error, no_permissions} = DownstreamResult,
                    CurrentBCounter
            end
    end.

-spec permissions_increment_check(dc1 | dc2, pos_integer(), antidote_crdt_counter_b:antidote_crdt_counter_b(), antidote_crdt_counter_b:antidote_crdt_counter_b()) -> antidote_crdt_counter_b:antidote_crdt_counter_b().
permissions_increment_check(Id, V, CurrentBCounter, NewBCounter) ->
    OtherId =
        case Id == dc1 of
            true -> dc2;
            false -> dc1
        end,
    PreviousLocalPermissionsId = antidote_crdt_counter_b:local_permissions(Id, CurrentBCounter),
    NewLocalPermissionsId = antidote_crdt_counter_b:local_permissions(Id, NewBCounter),
    V = NewLocalPermissionsId - PreviousLocalPermissionsId,
    PreviousLocalPermissionsOtherId = antidote_crdt_counter_b:local_permissions(OtherId, CurrentBCounter),
    NewLocalPermissionsOtherId = antidote_crdt_counter_b:local_permissions(OtherId, NewBCounter),
    NewLocalPermissionsOtherId = PreviousLocalPermissionsOtherId,
    PreviousTotalPermissions = antidote_crdt_counter_b:permissions(CurrentBCounter),
    NewTotalPermissions = antidote_crdt_counter_b:permissions(NewBCounter),
    V = NewTotalPermissions - PreviousTotalPermissions,
    NewBCounter.

-spec permissions_decrement_check(dc1 | dc2, pos_integer(), antidote_crdt_counter_b:antidote_crdt_counter_b(), antidote_crdt_counter_b:antidote_crdt_counter_b()) -> antidote_crdt_counter_b:antidote_crdt_counter_b().
permissions_decrement_check(Id, V, CurrentBCounter, NewBCounter) ->
    OtherId =
        case Id == dc1 of
            true -> dc2;
            false -> dc1
        end,
    PreviousLocalPermissionsId = antidote_crdt_counter_b:local_permissions(Id, CurrentBCounter),
    NewLocalPermissionsId = antidote_crdt_counter_b:local_permissions(Id, NewBCounter),
    V = PreviousLocalPermissionsId - NewLocalPermissionsId,
    PreviousLocalPermissionsOtherId = antidote_crdt_counter_b:local_permissions(OtherId, CurrentBCounter),
    NewLocalPermissionsOtherId = antidote_crdt_counter_b:local_permissions(OtherId, NewBCounter),
    NewLocalPermissionsOtherId = PreviousLocalPermissionsOtherId,
    PreviousTotalPermissions = antidote_crdt_counter_b:permissions(CurrentBCounter),
    NewTotalPermissions = antidote_crdt_counter_b:permissions(NewBCounter),
    V = PreviousTotalPermissions - NewTotalPermissions,
    NewBCounter.

-spec permissions_transfer_check(dc1 | dc2, dc1 | dc2, pos_integer(), antidote_crdt_counter_b:antidote_crdt_counter_b(), antidote_crdt_counter_b:antidote_crdt_counter_b()) -> antidote_crdt_counter_b:antidote_crdt_counter_b().
permissions_transfer_check(Id, Id, V, CurrentBCounter, NewBCounter) ->
    permissions_increment_check(Id, V, CurrentBCounter, NewBCounter);
permissions_transfer_check(ToId, FromId, V, CurrentBCounter, NewBCounter) ->
    PreviousLocalPermissionsId = antidote_crdt_counter_b:local_permissions(FromId, CurrentBCounter),
    NewLocalPermissionsId = antidote_crdt_counter_b:local_permissions(FromId, NewBCounter),
    V = PreviousLocalPermissionsId - NewLocalPermissionsId,
    PreviousLocalPermissionsOtherId = antidote_crdt_counter_b:local_permissions(ToId, CurrentBCounter),
    NewLocalPermissionsOtherId = antidote_crdt_counter_b:local_permissions(ToId, NewBCounter),
    V = NewLocalPermissionsOtherId - PreviousLocalPermissionsOtherId,
    PreviousTotalPermissions = antidote_crdt_counter_b:permissions(CurrentBCounter),
    NewTotalPermissions = antidote_crdt_counter_b:permissions(NewBCounter),
    PreviousTotalPermissions = NewTotalPermissions,
    NewBCounter.

%%%%%%%%%%%%%%%%%%
%%% Generators %%%
%%%%%%%%%%%%%%%%%%

-spec valid_operations() -> antidote_crdt_counter_b:antidote_crdt_counter_b_op().
valid_operations() ->
    oneof(
        [
            {oneof([increment, decrement]), oneof([pos_integer(), {pos_integer(), term()}])},
            {transfer, oneof([{pos_integer(), term()}, {pos_integer(), term(), term()}])}
        ]).

-spec invalid_negative_operations() -> term().
invalid_negative_operations() ->
    oneof(
        [
            {oneof([increment, decrement]), oneof([oneof([neg_integer(), 0]), {oneof([neg_integer(), 0]), term()}])},
            {transfer, oneof([{oneof([neg_integer(), 0]), term()}, {oneof([neg_integer(), 0]), term(), term()}])}
        ]).

valid_partial_operations() ->
    oneof(
        [
            {oneof([increment, decrement]), pos_integer()},
            {transfer, {pos_integer(), term()}}
        ]).

-spec get_increment_decrement_ops() ->
    {{increment, {pos_integer(), undefined}}, {decrement, {pos_integer(), undefined}}}.
get_increment_decrement_ops() ->
    {{increment, {pos_integer(), undefined}}, {decrement, {pos_integer(), undefined}}}.

-spec get_random_ops_with_two_possible_ids() -> [antidote_crdt_counter_b:antidote_crdt_counter_b_full_op()].
get_random_ops_with_two_possible_ids() ->
    list(oneof(
        [
            {oneof([increment, decrement]), {pos_integer(), oneof([dc1, dc2])}},
            {transfer, {pos_integer(), oneof([dc1, dc2]), oneof([dc1, dc2])}}
        ]
    )).

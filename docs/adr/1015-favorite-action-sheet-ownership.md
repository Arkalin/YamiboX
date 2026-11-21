# Keep favorite action sheets on a stable host

Attach [favorite action presentations](../../Sources/YamiboXUI/Features/Favorites/Shared/FavoriteActionInterface.swift) to a stable view when a row supplies the action controller. The row chooses the subject but does not own its sheet; swapping the controller must not replace the host view or reset its state.

[Confirmation sheets](../../Sources/YamiboXUI/Features/Favorites/Shared/FavoriteQuickActionDialogs.swift) capture the chosen subject and action before clearing the binding, then dispatch the mutation after dismissal. Firing the mutation from inside the presented sheet would let a fast failure compete with its dismissal for presentation; reading the subject from the binding after dismissal would lose it.

The [action controller](../../Sources/YamiboXUI/Features/Favorites/Engine/FavoriteActionController.swift) records observed store changes during command preflight without starting a competing refresh. Preflight retries on a newer revision and any pending refresh runs after the command. A location picker can outlive changes to a smart-manga group's membership; if an unfavorited thread now belongs to a favorited group, submission opens group location management rather than interpreting the earlier empty selection as deletion.

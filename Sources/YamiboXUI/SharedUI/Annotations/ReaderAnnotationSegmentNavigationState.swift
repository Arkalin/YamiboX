/// State each segment reports to the panel-owned navigation item.
///
/// Keeping this compact value at the panel boundary prevents a segment swap
/// from temporarily owning an incomplete navigation bar during layout.
struct ReaderAnnotationSegmentNavigationState: Equatable {
    var itemCount = 0
    var isSelecting = false
    var selectedItemCount = 0
    var selectionTitle: String?
}

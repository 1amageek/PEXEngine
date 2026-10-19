import CircuiteFoundation
import LEF
import PEXNative

struct NativeRoutedPEXDecodedLEF {
    let document: LEFDocument
    let reference: ArtifactReference
    var fact: NativeRoutedPEXInput.SourceFact {
        .init(artifactID: reference.id, byteRange: .init(lowerBound: 0, upperBound: Int(reference.id.byteCount)))
    }
}

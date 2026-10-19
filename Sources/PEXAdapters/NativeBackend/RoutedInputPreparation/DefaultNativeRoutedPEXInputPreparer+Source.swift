import Foundation
import LogicKernelCore
import LogicDesignSerialization

extension DefaultNativeRoutedPEXInputPreparer {
    func decodeSource(_ bytes: Data, top: String, limits: NativeRoutedPEXPreparationLimits,
                      budget: inout NativeRoutedPEXPreparationBudget, isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXPreparationError) -> StructuralVerilogSource {
        try budget.visit(isCancelled: isCancelled)
        guard budget.remainingRecords > 0, budget.remainingStringBytes > 0, budget.remainingWorkVisits > 0 else {
            throw .limitExceeded("netlistRemainingBudget")
        }
        do {
            // The synchronous context is destroyed before this closure returns. Neither
            // the immutable source DTO nor any result retains the borrowed callback.
            return try withoutActuallyEscaping(isCancelled) { callback in
                var maximums = Dictionary(uniqueKeysWithValues: LogicResource.allCases.map { ($0, UInt64(1)) })
                maximums[.expansion] = UInt64(limits.maximumSourceBytes)
                maximums[.workUnits] = UInt64(budget.remainingWorkVisits)
                maximums[.nodes] = UInt64(budget.remainingRecords)
                maximums[.outputBytes] = UInt64(budget.remainingStringBytes)
                maximums[.managedStorageBytes] = limits.maximumNetlistManagedStorageBytes
                maximums[.allocationBytes] = limits.maximumNetlistAllocationBytes
                maximums[.storageReservations] = 3
                var context = LogicKernelContext(limits: try .init(maximums: maximums),
                    control: NativeRoutedPEXSourceControl(isCancelled: callback))
                let source = try decoder.decodeSource(bytes, top: top, context: &context)
                let usage = context.usage
                guard let work = Int(exactly: usage[.workUnits]), let records = Int(exactly: usage[.nodes]),
                      let strings = Int(exactly: usage[.outputBytes]) else {
                    throw NativeRoutedPEXPreparationError.arithmeticOverflow
                }
                try budget.visit(work, isCancelled: isCancelled)
                try budget.record(records); try budget.reserveStringBytes(strings)
                return source
            }
        } catch let error as NativeRoutedPEXPreparationError { throw error }
        catch StructuralVerilogSourceError.kernel(.cancelled) { throw .cancelled }
        catch LogicKernelError.cancelled { throw .cancelled }
        catch StructuralVerilogSourceError.kernel(.resourceLimit(let resource, _, _)) {
            switch resource {
            case .managedStorageBytes: throw .limitExceeded("netlistManagedStorageBytes")
            case .allocationBytes: throw .limitExceeded("netlistAllocationBytes")
            case .workUnits: throw .limitExceeded("workVisits")
            case .nodes: throw .limitExceeded("records")
            case .outputBytes: throw .limitExceeded("stringBytes")
            default: throw .limitExceeded("netlistKernelResource-\(resource.rawValue)")
            }
        }
        catch { throw .sourceDecode("Owned structural Verilog decoder refused source: \(error)") }
    }
}

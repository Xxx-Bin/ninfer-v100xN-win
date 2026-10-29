// Portable LP64 `sgemm_` for hosts without a BLAS provider.
//
// The CPU vision tower calls the Fortran LP64 ABI directly (src/ops/host/vision.cpp). Linux
// resolves it from the system BLAS; a Windows host usually has no OpenBLAS/MKL installed, and the
// product must still build there. This translation unit provides the same symbol so the tower
// stays functional, at BLAS-free speed: column-major, single threaded, j-k-i ordering so the inner
// loop walks A down a column and C across a row, which is the sequential-access case for both.
//
// It is selected only when find_package(BLAS) fails; a real BLAS always wins.
#include <cstddef>

extern "C" void sgemm_(const char* transa, const char* transb, const int* m, const int* n,
                       const int* k, const float* alpha, const float* a, const int* lda,
                       const float* b, const int* ldb, const float* beta, float* c,
                       const int* ldc) {
    if (m == nullptr || n == nullptr || k == nullptr || a == nullptr || b == nullptr ||
        c == nullptr || lda == nullptr || ldb == nullptr || ldc == nullptr || alpha == nullptr ||
        beta == nullptr) {
        return;
    }
    const int rows        = *m;
    const int columns     = *n;
    const int depth       = *k;
    const bool a_transposed = transa != nullptr && (*transa == 'T' || *transa == 't');
    const bool b_transposed = transb != nullptr && (*transb == 'T' || *transb == 't');
    const float scale_a   = *alpha;
    const float scale_c   = *beta;

    // C = beta * C first, so the accumulation below is a plain sum.
    for (int column = 0; column < columns; ++column) {
        float* destination = c + static_cast<std::ptrdiff_t>(column) * (*ldc);
        if (scale_c == 0.0F) {
            for (int row = 0; row < rows; ++row) { destination[row] = 0.0F; }
        } else if (scale_c != 1.0F) {
            for (int row = 0; row < rows; ++row) { destination[row] *= scale_c; }
        }
    }
    if (scale_a == 0.0F || rows <= 0 || columns <= 0 || depth <= 0) { return; }

    const std::ptrdiff_t stride_a_row = a_transposed ? 1 : *lda;
    const std::ptrdiff_t stride_a_k   = a_transposed ? *lda : 1;
    const std::ptrdiff_t stride_b_k   = b_transposed ? 1 : *ldb;
    const std::ptrdiff_t stride_b_col = b_transposed ? *ldb : 1;

    for (int column = 0; column < columns; ++column) {
        float* destination = c + static_cast<std::ptrdiff_t>(column) * (*ldc);
        const float* b_column = b + static_cast<std::ptrdiff_t>(column) * stride_b_col;
        for (int inner = 0; inner < depth; ++inner) {
            const float factor = scale_a * b_column[static_cast<std::ptrdiff_t>(inner) * stride_b_k];
            if (factor == 0.0F) { continue; }
            const float* a_column = a + static_cast<std::ptrdiff_t>(inner) * stride_a_k;
            for (int row = 0; row < rows; ++row) {
                destination[row] += factor * a_column[static_cast<std::ptrdiff_t>(row) * stride_a_row];
            }
        }
    }
}

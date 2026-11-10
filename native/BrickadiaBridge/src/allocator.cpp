// Global operator new/delete for this module, over libc malloc/free.
//
// The server executable exports its own operator new/delete (snmalloc via
// FMemory) and comes first in symbol lookup, so without these the module's
// allocations would go to the game's heap. libUE4SS.so links libstdc++
// statically with -Bsymbolic, so its strings and containers live on the libc
// heap; anything it returns by value and this module destroys must be freed
// there too. -Bsymbolic (see CMakeLists.txt) binds these definitions locally.
#include <cstdlib>
#include <new>

namespace
{
    auto allocate(std::size_t size) -> void*
    {
        if (void* p = std::malloc(size ? size : 1)) { return p; }
        throw std::bad_alloc{};
    }

    auto allocate_aligned(std::size_t size, std::align_val_t align) -> void*
    {
        void* p{};
        const auto a = static_cast<std::size_t>(align) < sizeof(void*) ? sizeof(void*) : static_cast<std::size_t>(align);
        if (posix_memalign(&p, a, size ? size : 1) == 0) { return p; }
        throw std::bad_alloc{};
    }
} // namespace

void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept { return std::malloc(size ? size : 1); }
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept { return std::malloc(size ? size : 1); }
void* operator new(std::size_t size, std::align_val_t align) { return allocate_aligned(size, align); }
void* operator new[](std::size_t size, std::align_val_t align) { return allocate_aligned(size, align); }

void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
void operator delete(void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete(void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { std::free(p); }

#!/bin/bash

# DNS Cache Benchmarks Runner
#
# This script runs all cache benchmarks and generates a comprehensive report.
#
# Usage:
#   ./scripts/run_cache_benchmarks.sh [options]
#
# Options:
#   --quick          Run quick benchmarks (shorter duration)
#   --full           Run full benchmark suite (default)
#   --performance    Run only performance tests
#   --load           Run only load tests
#   --report-only    Generate report only (skip benchmarks)
#   --help           Show this help message

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
RUN_BENCHEE=true
RUN_PERFORMANCE=true
RUN_LOAD=true
RUN_REPORT=true
BENCHMARK_TIME=5

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --quick)
      BENCHMARK_TIME=2
      shift
      ;;
    --full)
      BENCHMARK_TIME=10
      shift
      ;;
    --performance)
      RUN_BENCHEE=false
      RUN_LOAD=false
      shift
      ;;
    --load)
      RUN_BENCHEE=false
      RUN_PERFORMANCE=false
      shift
      ;;
    --report-only)
      RUN_BENCHEE=false
      RUN_PERFORMANCE=false
      RUN_LOAD=false
      shift
      ;;
    --help)
      grep "^#" "$0" | grep -v "#!/bin/bash" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Print header
echo -e "${BLUE}"
echo "================================================================================"
echo "                    DNS CACHE BENCHMARK SUITE"
echo "================================================================================"
echo -e "${NC}"
echo ""
echo "Starting benchmark run at $(date)"
echo ""

# Change to the DNS app directory
cd "$(dirname "$0")/.."

# Check if we're in the right directory
if [ ! -f "mix.exs" ]; then
  echo -e "${RED}Error: mix.exs not found. Are you in the yellow_dog_dns directory?${NC}"
  exit 1
fi

# Create output directory for results
OUTPUT_DIR="benchmark_results"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$OUTPUT_DIR/benchmark_report_${TIMESTAMP}.txt"

# Function to print section header
print_section() {
  echo ""
  echo -e "${GREEN}================================================================================"
  echo "  $1"
  echo -e "================================================================================${NC}"
  echo ""
}

# Function to run a benchmark step
run_step() {
  local name=$1
  local command=$2

  echo -e "${YELLOW}▶ Running: $name${NC}"
  echo ""

  if eval "$command"; then
    echo ""
    echo -e "${GREEN}✓ $name completed successfully${NC}"
    return 0
  else
    echo ""
    echo -e "${RED}✗ $name failed${NC}"
    return 1
  fi
}

# Track failures
FAILED=0

# Run Benchee benchmarks
if [ "$RUN_BENCHEE" = true ]; then
  print_section "Running Benchee Benchmarks"

  if run_step "Cache Operations Benchmark" "mix run bench/cache_bench.exs 2>&1 | tee $OUTPUT_DIR/benchee_${TIMESTAMP}.txt"; then
    :
  else
    FAILED=$((FAILED + 1))
  fi
fi

# Run performance tests
if [ "$RUN_PERFORMANCE" = true ]; then
  print_section "Running Performance Tests"

  if run_step "Performance Test Suite" "MIX_ENV=test mix test test/yellow_dog/dns/cache_performance_test.exs --include performance 2>&1 | tee $OUTPUT_DIR/performance_${TIMESTAMP}.txt"; then
    :
  else
    FAILED=$((FAILED + 1))
  fi
fi

# Run load tests
if [ "$RUN_LOAD" = true ]; then
  print_section "Running Load Tests"

  if run_step "Load Test Suite" "MIX_ENV=test mix test test/yellow_dog/dns/cache_load_test.exs --include load 2>&1 | tee $OUTPUT_DIR/load_${TIMESTAMP}.txt"; then
    :
  else
    FAILED=$((FAILED + 1))
  fi
fi

# Generate comprehensive report
if [ "$RUN_REPORT" = true ]; then
  print_section "Generating Comprehensive Report"

  if run_step "Report Generation" "mix run scripts/generate_benchmark_report.exs 2>&1 | tee $REPORT_FILE"; then
    :
  else
    FAILED=$((FAILED + 1))
  fi
fi

# Print summary
echo ""
echo -e "${BLUE}"
echo "================================================================================"
echo "                         BENCHMARK SUITE COMPLETE"
echo "================================================================================"
echo -e "${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}✓ All benchmarks completed successfully!${NC}"
else
  echo -e "${RED}✗ $FAILED benchmark(s) failed${NC}"
fi

echo ""
echo "Results saved to:"
echo "  - Output directory: $OUTPUT_DIR"
if [ "$RUN_REPORT" = true ]; then
  echo "  - Comprehensive report: $REPORT_FILE"
fi
echo ""
echo "Completed at $(date)"
echo ""

# Exit with appropriate code
exit $FAILED

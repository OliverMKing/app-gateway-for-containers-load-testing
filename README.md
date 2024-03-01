# app-gateway-for-containers-load-testing

Verify current subscription with `az account show`. If that's not the correct subscription then run `az account set --subscription <subscription>` to set it. Then run `./setup.sh` to setup the load test infrastructure. The output of this script are the two urls you need to enter into Azure Load Testing. [Follow the ALT instructions to create url-based load tests](https://learn.microsoft.com/en-us/azure/load-testing/quickstart-create-and-run-load-test?wt.mc_id=loadtesting_acomresources_webpage_cnl&tabs=azure-cli#create-an-azure-load-testing-resource).

Note: you might have to `chmod 755 setup.sh`.

If you want to compare your results to a live website then use `curl -w "@curl-format.txt" -o /dev/null -s "https://en.wikipedia.org/wiki/Kubernetes"`. You can also port-forward your Kubernetes service then run this command to compare to just connecting to the upstream application directly.

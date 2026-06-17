docker compose build

#Delpoy to swarm 
./deploy.sh

#Scale gateway
./scale.sh 5

#Run integration test
./test.sh 
